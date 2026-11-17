import Foundation
import GRDB
import XCTest
@testable import AgentBoardCore

/// SPEC §13.2: the author's ruling on an item outranks triage's verdict.
final class PRTriageRulingTests: XCTestCase {
    func testSetVerdictsRefusesAnythingButDecisionOnARuledItemAndWritesNothing() throws {
        let f = try Fixture.make()
        let store = PRWatchStore(f.db)
        let (watch, items) = try PRRulingFixtures.watch(f, threads: ["ASK", "NEW"])
        let (asked, untriaged) = (try XCTUnwrap(items[0].id), try XCTUnwrap(items[1].id))
        try PRRulingFixtures.ask(f, itemId: asked)
        try f.board.answerDecision(itemId: asked, choice: .option("Rename it everywhere"))

        XCTAssertThrowsError(try store.setVerdicts([
            PRVerdictInput(itemId: asked, verdict: .fix, approach: "Delete the alias instead."),
            PRVerdictInput(itemId: untriaged, verdict: .answer, approach: "Factual.", replyBody: "Yes."),
        ], watchId: watch.id)) {
            let reason = ($0 as? PRVerdictRejection)?.reason ?? "\($0)"
            XCTAssertTrue(reason.contains("Rename it everywhere"), reason)
        }

        let after = try store.items(watchId: watch.id)
        XCTAssertEqual(after.map(\.verdict), [.fix, nil])
        XCTAssertEqual(after.first?.approach, "Rename it everywhere")
        XCTAssertNoThrow(try store.setVerdicts([
            PRVerdictInput(
                itemId: asked, verdict: .decision, approach: "The reviewer pushed back.",
                decisionQuestion: "You chose to rename it everywhere; does that still hold?",
                decisionOptions: [
                    PRDecisionOption(label: "Yes", verdict: .fix),
                    PRDecisionOption(label: "No", verdict: .answer, replyBody: "Keeping it."),
                ]
            ),
        ], watchId: watch.id))
    }
}

enum PRRulingFixtures {
    static func watch(_ f: Fixture, threads: [String]) throws -> (PRWatch, [PRItem]) {
        let store = PRWatchStore(f.db)
        let watch = try store.upsert(
            projectId: f.project.id, snapshot: snapshot(threads.map { thread($0) }), now: 1_000
        )
        return (watch, try store.items(watchId: watch.id))
    }

    static func snapshot(_ items: [PRSnapshotItem]) -> PRSnapshot {
        PRSnapshot(
            repoOwner: "octo", repoName: "example", number: 7, url: "https://github.com/octo/example/pull/7",
            title: "Add a widget", headRef: "feature/widget", headOid: "abc123", baseRef: "main",
            reviewDecision: "REVIEW_REQUIRED", checksState: "SUCCESS", mergeable: "MERGEABLE", labels: [],
            items: items
        )
    }

    static func thread(_ id: String, body: String = "Rename this") -> PRSnapshotItem {
        PRSnapshotItem(
            githubNodeId: id, kind: .thread, author: "reviewer", body: body, path: "Sources/A.swift", line: 12,
            url: "https://github.com/octo/example/pull/7#discussion_\(id)", isResolved: false
        )
    }

    static func ask(_ f: Fixture, itemId: Int64) throws {
        let options = PRWatchStore.encodeOptions([
            PRDecisionOption(label: "Rename it everywhere", verdict: .fix),
            PRDecisionOption(label: "Keep the name", verdict: .answer, replyBody: "The old name is public API."),
        ])
        try f.db.writer.write { db in
            try db.execute(
                sql: """
                UPDATE pr_item SET verdict = 'decision', approach = 'Direction.', decision_question = 'Rename it?',
                decision_options_json = ? WHERE id = ?
                """,
                arguments: [options, itemId]
            )
        }
    }
}
