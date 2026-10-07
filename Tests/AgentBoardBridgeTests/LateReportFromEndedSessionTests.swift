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
}
