import AgentBoardCore
import Foundation
import GRDB
import UserNotifications
import XCTest
@testable import AgentBoard

/// SPEC §15.6: a typed Deny or Reply on a banner writes one ruling through the Inbox's answer path and
/// grants, posts and spawns nothing. The delegate is driven with a constructed response; no banner is shown.
@MainActor
final class BannerAnswerTests: XCTestCase {
    private var fixture: SupervisorFixture!
    private var responder: NotificationResponder!
    private var opened: [NotificationRoute] = []

    override func setUp() async throws {
        fixture = try SupervisorFixture.make()
        opened = []
        let answering = BannerAnswering(db: fixture.db, supervisor: fixture.supervisor)
        responder = NotificationResponder(
            open: { [weak self] in self?.opened.append($0) },
            answer: { question, text in _ = await answering.answer(question, text: text) }
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: fixture.supportDir)
        fixture = nil
    }

    func testATypedDenyWritesOneRulingGrantsNothingAndASecondBannerWritesNoMore() async throws {
        let approval = try fixture.approvals.create(
            projectId: fixture.project.id, kind: .spawn, taskId: nil, epicId: nil,
            requestedBy: "orchestrator", reason: "spawn a worker"
        )
        let question = BannerQuestion(kind: .approval, subjectId: approval.id, questionAt: approval.createdAt)
        let response = try typed(question, "Not this week")

        await responder.respond(to: response)
        await responder.respond(to: response)

        let rulings = try rulings()
        XCTAssertEqual(rulings.map(\.verdict), [.deny])
        XCTAssertEqual(rulings.first?.note, "Not this week")
        XCTAssertEqual(try fixture.approvals.get(approval.id)?.resolution, .denied)
        let spawns = await fixture.runtime.spawns
        XCTAssertEqual(spawns.count, 0)
        XCTAssertEqual(fixture.gh.calls, [])
        XCTAssertEqual(opened, [], "a typed answer must not open the window")
    }

    func testATypedReplyRecordsTheReplyOwedAndPostsNothing() async throws {
        var settings = fixture.project.settings
        settings.prFollowThrough.enabled = true
        try ProjectStore(fixture.db).updateSettings(fixture.project.id, settings)
        let projectId = fixture.project.id
        try await fixture.db.writer.write { db in
            try db.execute(sql: """
                INSERT INTO pr_watch (id, project_id, repo_owner, repo_name, number, url, title, head_ref, head_oid,
                  base_ref, state, created_at, updated_at)
                VALUES ('w1', ?, 'octo', 'example', 1, 'u', 'Widget', 'h', 'oid', 'main', 'watching', 0, 0);
                INSERT INTO pr_item (id, watch_id, github_node_id, kind, body, state, verdict, decision_question,
                  decision_notified_at, created_at, updated_at)
                VALUES (7, 'w1', 'n1', 'thread', 'Rename?', 'open', 'decision', 'Rename it?', 400, 50, 400);
                """, arguments: [projectId])
        }

        await responder.respond(to: try typed(BannerQuestion(kind: .prDecision, subjectId: "7", questionAt: 400), "Keep the name"))

        XCTAssertEqual(try rulings().map(\.verdict), [.reply])
        let item = try XCTUnwrap(try PRWatchStore(fixture.db).item(7))
        XCTAssertEqual(item.replyBody, "Keep the name")
        XCTAssertNil(item.replyURL)
        XCTAssertEqual(fixture.gh.calls, [])
    }

    private func rulings() throws -> [Ruling] {
        try fixture.db.reader.read { try Ruling.fetchAll($0) }
    }

    private func typed(_ question: BannerQuestion, _ text: String) throws -> UNNotificationResponse {
        let content = UNMutableNotificationContent()
        content.userInfo = NotificationRoute(projectId: fixture.project.id, subject: .approvals, question: question).userInfo
        content.categoryIdentifier = question.kind.categoryIdentifier
        let notification = try XCTUnwrap((FakeNotification.self as NSObject.Type).init() as? FakeNotification)
        notification.stubbedRequest = UNNotificationRequest(identifier: "banner", content: content, trigger: nil)
        let response = try XCTUnwrap((FakeTextResponse.self as NSObject.Type).init() as? FakeTextResponse)
        response.stubbedAction = question.kind.actionIdentifier
        response.stubbedText = text
        response.stubbedNotification = notification
        return response
    }
}

/// `UNNotification` and its responses mark `init` unavailable to Swift; the runtime still accepts it
/// through an `NSObject` metatype, and the overridden accessors are all the delegate reads.
private final class FakeNotification: UNNotification, @unchecked Sendable {
    var stubbedRequest: UNNotificationRequest!
    override var request: UNNotificationRequest { stubbedRequest }
}

private final class FakeTextResponse: UNTextInputNotificationResponse, @unchecked Sendable {
    var stubbedAction = ""
    var stubbedText = ""
    var stubbedNotification: UNNotification!
    override var actionIdentifier: String { stubbedAction }
    override var userText: String { stubbedText }
    override var notification: UNNotification { stubbedNotification }
}
