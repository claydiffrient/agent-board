import AgentBoardBridge
import AgentBoardCore
import AgentBoardServer
import Foundation
import XCTest

/// SPEC §5.1: a `report_complete` from a session Agent Board already ended moves nothing. Replays
/// integration task 006dfd78 on 2026-10-07, where the idle-capped first integrator reported two
/// minutes after the second one had closed the epic, and pulled the archived task back into review.
final class LateReportFromEndedSessionTests: XCTestCase {
    private var f: BridgeFixture!

    override func setUpWithError() throws {
        f = try BridgeFixture.make()
    }

    func testALateReportFromAnIdleCappedIntegratorLeavesTheArchivedTaskInDone() async throws {
        let epic = try f.epic("Assessment Taking Enhancements", state: .integrating)
        let integration = try f.board.createIntegrationTask(epicId: epic.id)
        let arguments: JSONValue = .object([
            "summary": .string("merged every branch"),
            "files_changed": .array([]),
            "tests_run": .string("bb test //..."),
            "caveats": .string(""),
        ])

        try f.session("d44b3f51", taskId: integration.id)
        try f.tasks.move(integration.id, to: .running)
        try f.board.terminate(sessionId: "d44b3f51", cause: .capBreach("idle cap reached: no activity for 5 minutes (limit 5)"))

        try f.session("c6283212", taskId: integration.id)
        try f.tasks.move(integration.id, to: .running)
        _ = try await f.scoped.call(
            "report_complete", arguments: arguments,
            identity: f.workerIdentity(sessionId: "c6283212", taskId: integration.id)
        )
        let closed = try XCTUnwrap(f.tasks.get(integration.id))
        XCTAssertEqual(closed.column, .done)
        XCTAssertNotNil(closed.archivedAt)

        let late = try await f.scoped.call(
            "report_complete", arguments: arguments,
            identity: f.workerIdentity(sessionId: "d44b3f51", taskId: integration.id)
        )

        let after = try XCTUnwrap(f.tasks.get(integration.id))
        XCTAssertEqual(after.column, .done)
        XCTAssertEqual(after.archivedAt, closed.archivedAt)
        XCTAssertEqual(after.landing, closed.landing)
        XCTAssertEqual(try f.sessions.get("d44b3f51")?.state, .failed)
        XCTAssertFalse(late.isError)
        XCTAssertTrue(late.text.contains("had already ended this session (failed)"), late.text)
        XCTAssertTrue(late.text.contains("it stays in Done"), late.text)
    }

    func testALateReportFromAnEndedIntegratorLeavesAnIntegratedEpicAndItsTaskAlone() async throws {
        let epic = try f.epic("Ship search", state: .integrating)
        try EpicStore(f.db).setShipsByPullRequest(epic.id, true)
        let integration = try f.board.createIntegrationTask(epicId: epic.id)
        let arguments: JSONValue = .object(["summary": .string("merged everything"), "files_changed": .array([])])

        try f.session("first", taskId: integration.id)
        try f.tasks.move(integration.id, to: .running)
        try f.board.terminate(sessionId: "first", cause: .capBreach("idle cap reached"))
        try f.session("second", taskId: integration.id)
        try f.tasks.move(integration.id, to: .running)
        _ = try await f.scoped.call(
            "report_complete", arguments: arguments,
            identity: f.workerIdentity(sessionId: "second", taskId: integration.id)
        )
        let openPullRequest = "open_pull_request(epic_id: \"\(epic.id)\""
        func announcements() throws -> Int {
            try f.reports.unconsumed(projectId: f.project.id).filter { $0.body.contains(openPullRequest) }.count
        }
        let integrated = try XCTUnwrap(f.tasks.get(integration.id))
        XCTAssertEqual(try EpicStore(f.db).get(epic.id)?.state, .integrated)
        XCTAssertEqual(try announcements(), 1)

        let late = try await f.scoped.call(
            "report_complete", arguments: arguments,
            identity: f.workerIdentity(sessionId: "first", taskId: integration.id)
        )

        XCTAssertFalse(late.isError, late.text)
        XCTAssertTrue(late.text.contains("had already ended this session (failed)"), late.text)
        XCTAssertFalse(late.text.contains("stays open until its pull request merges"), late.text)
        XCTAssertEqual(try EpicStore(f.db).get(epic.id)?.state, .integrated)
        XCTAssertEqual(try announcements(), 1, "the late report re-announced the epic's pull request")
        let after = try XCTUnwrap(f.tasks.get(integration.id))
        XCTAssertEqual(after.column, integrated.column)
        XCTAssertEqual(after.landing, integrated.landing)
        XCTAssertEqual(after.reviewerAgentId, integrated.reviewerAgentId)
        XCTAssertEqual(try f.sessions.get("first")?.state, .failed)
    }
}
