import Foundation
import GRDB
import XCTest
@testable import AgentBoardCore

/// `MessageStore.conversation` is what the orchestrator sidebar reads: both directions of a
/// project's message traffic, each row naming the other project and saying whether the receiving
/// orchestrator has pulled it.
final class MessageConversationTests: XCTestCase {
    private func project(_ f: Fixture, _ name: String) throws -> Project {
        try f.projects.register(
            name: name, repoPath: "/tmp/\(name)-\(UUID().uuidString)", baseBranch: "main",
            worktreeRoot: "/tmp/\(name)-worktrees", memoryDir: nil
        )
    }

    func testBothDirectionsAppearWithTheOtherProjectNamed() throws {
        let f = try Fixture.make()
        let beta = try project(f, "Beta")

        try f.messages.send(
            fromProjectId: f.project.id, fromSessionId: nil, toProjectId: beta.id,
            body: "Can you rebase onto the new schema?"
        )
        try f.messages.send(
            fromProjectId: beta.id, fromSessionId: nil, toProjectId: f.project.id,
            body: "Rebased; the migration list changed."
        )

        let entries = try f.messages.conversation(projectId: f.project.id)
        XCTAssertEqual(entries.count, 2)
        // Newest first.
        XCTAssertEqual(entries[0].direction, .received)
        XCTAssertEqual(entries[0].otherProjectName, "Beta")
        XCTAssertEqual(entries[0].otherProjectId, beta.id)
        XCTAssertEqual(entries[0].body, "Rebased; the migration list changed.")
        XCTAssertEqual(entries[1].direction, .sent)
        XCTAssertEqual(entries[1].otherProjectName, "Beta")
        XCTAssertEqual(entries[1].body, "Can you rebase onto the new schema?")
    }

    /// The sender's row carries the sender's own words, not the framed `deliveredBody` the recipient
    /// reads — the human looking at a sent message wants what their orchestrator wrote.
    func testTheStoredBodyIsTheSendersWordsNotTheFraming() throws {
        let f = try Fixture.make()
        let beta = try project(f, "Beta")
        try f.messages.send(
            fromProjectId: f.project.id, fromSessionId: nil, toProjectId: beta.id, body: "  ping  "
        )

        let sent = try XCTUnwrap(try f.messages.conversation(projectId: f.project.id).first)
        XCTAssertEqual(sent.body, "ping")
        XCTAssertFalse(sent.body.contains(f.project.name))
    }

    func testConsumptionIsReadFromTheDeliveredReportForBothDirections() throws {
        let f = try Fixture.make()
        let beta = try project(f, "Beta")

        try f.messages.send(
            fromProjectId: f.project.id, fromSessionId: nil, toProjectId: beta.id, body: "outbound"
        )
        try f.messages.send(
            fromProjectId: beta.id, fromSessionId: nil, toProjectId: f.project.id, body: "inbound"
        )

        XCTAssertEqual(
            try f.messages.conversation(projectId: f.project.id).map(\.isConsumed), [false, false]
        )

        // Beta's orchestrator pulls its queue: only the message we sent becomes consumed.
        try f.reports.consumeAll(projectId: beta.id)
        let afterBetaRead = try f.messages.conversation(projectId: f.project.id)
        XCTAssertEqual(afterBetaRead.first { $0.direction == .sent }?.isConsumed, true)
        XCTAssertEqual(afterBetaRead.first { $0.direction == .received }?.isConsumed, false)

        try f.reports.consumeAll(projectId: f.project.id)
        XCTAssertEqual(
            try f.messages.conversation(projectId: f.project.id).map(\.isConsumed), [true, true]
        )
    }

    func testAThirdProjectsTrafficIsNotShown() throws {
        let f = try Fixture.make()
        let beta = try project(f, "Beta")
        let gamma = try project(f, "Gamma")

        try f.messages.send(
            fromProjectId: beta.id, fromSessionId: nil, toProjectId: gamma.id, body: "not ours"
        )

        XCTAssertEqual(try f.messages.conversation(projectId: f.project.id), [])
        XCTAssertEqual(try f.messages.conversation(projectId: beta.id).count, 1)
        XCTAssertEqual(try f.messages.conversation(projectId: gamma.id).count, 1)
    }

    /// A project may message itself (`MessageStore.send` permits it). One `message` row must produce
    /// one row on the board, not a sent/received pair.
    func testASelfAddressedMessageAppearsOnceAsReceived() throws {
        let f = try Fixture.make()
        try f.messages.send(
            fromProjectId: f.project.id, fromSessionId: nil, toProjectId: f.project.id,
            body: "note to self"
        )

        let entries = try f.messages.conversation(projectId: f.project.id)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].direction, .received)
        XCTAssertEqual(entries[0].otherProjectName, f.project.name)
    }

    /// Each write is issued from inside the observation loop, so an emission that arrives is proof
    /// the observation produced it — nothing here polls, and no emission count is assumed.
    func testTheObservationEmitsWhenAMessageArrivesAndWhenItIsConsumed() async throws {
        let f = try Fixture.make()
        let beta = try project(f, "Beta")

        var stage = 0
        var arrived: [MessageEntry] = []
        var afterRead: [MessageEntry] = []

        for try await entries in f.messages.observeConversation(projectId: f.project.id)
            .values(in: f.db.reader)
        {
            switch stage {
            case 0:
                XCTAssertEqual(entries, [], "no traffic before the first send")
                stage = 1
                try f.messages.send(
                    fromProjectId: beta.id, fromSessionId: nil, toProjectId: f.project.id,
                    body: "hello"
                )
            case 1:
                guard entries.count == 1 else { continue }
                arrived = entries
                stage = 2
                try f.reports.consumeAll(projectId: f.project.id)
            default:
                guard entries.first?.isConsumed == true else { continue }
                afterRead = entries
            }
            if !afterRead.isEmpty { break }
        }

        XCTAssertEqual(arrived.map(\.body), ["hello"])
        XCTAssertEqual(arrived.map(\.isConsumed), [false])
        XCTAssertEqual(afterRead.map(\.isConsumed), [true], "consuming the report must re-emit")
    }
}
