import Foundation
import XCTest
@testable import AgentBoardCore

/// Every board change the orchestrator cannot observe for itself has to leave a report behind.
final class BoardAnnouncementTests: XCTestCase {
    private var f: Fixture!

    override func setUpWithError() throws {
        f = try Fixture.make()
    }

    private func pending() throws -> [Report] {
        try f.reports.unconsumed(projectId: f.project.id)
    }

    // MARK: Accept

    func testAcceptReportsTheNewlyReadyDependents() throws {
        let blocker = try f.task("build the parser", column: .review)
        let first = try f.task("use the parser")
        let second = try f.task("document the parser")
        let unrelated = try f.task("still blocked")
        let otherBlocker = try f.task("not done yet")
        try f.tasks.setDeps(first.id, dependsOn: [blocker.id])
        try f.tasks.setDeps(second.id, dependsOn: [blocker.id])
        try f.tasks.setDeps(unrelated.id, dependsOn: [otherBlocker.id])
        try f.tasks.refreshReadiness(projectId: f.project.id)

        let ready = try f.board.accept(taskId: blocker.id)
        XCTAssertEqual(Set(ready), [first.id, second.id])

        let reports = try pending()
        XCTAssertEqual(reports.count, 1)
        let report = try XCTUnwrap(reports.first)
        XCTAssertEqual(report.kind, .decision)
        XCTAssertEqual(report.taskId, blocker.id)
        XCTAssertTrue(report.body.contains(blocker.id), report.body)
        XCTAssertTrue(report.body.contains("build the parser"), report.body)
        XCTAssertTrue(report.body.contains(first.id), report.body)
        XCTAssertTrue(report.body.contains(second.id), report.body)
        XCTAssertTrue(report.body.contains("use the parser"), report.body)
        XCTAssertFalse(report.body.contains(unrelated.id), report.body)
    }

    func testAcceptWithNoDependentsStillReports() throws {
        let task = try f.task("standalone", column: .review)

        XCTAssertEqual(try f.board.accept(taskId: task.id), [])

        let report = try XCTUnwrap(pending().first)
        XCTAssertEqual(report.kind, .decision)
        XCTAssertTrue(report.body.contains("No other task became ready"), report.body)
    }

    // MARK: App-initiated termination

    func testCapKillReportsTheFailureReasonAndReturnsTheTaskToReady() throws {
        let task = try f.task("critical path", column: .ready)
        try f.board.assign(taskId: task.id, session: f.session("w1", state: .running))
        let breach = "idle cap reached: no activity for 5 minutes (limit 5)"

        let report = try XCTUnwrap(f.board.terminate(sessionId: "w1", cause: .capBreach(breach)))

        XCTAssertEqual(report.kind, .failed)
        XCTAssertEqual(report.taskId, task.id)
        XCTAssertEqual(report.sessionId, "w1")
        XCTAssertTrue(report.body.contains(breach), report.body)
        XCTAssertTrue(report.body.contains(task.id), report.body)
        XCTAssertTrue(report.body.contains("w1"), report.body)
        XCTAssertEqual(try pending().map(\.id), [report.id])

        let killed = try XCTUnwrap(f.tasks.get(task.id))
        XCTAssertEqual(killed.column, .ready)
        XCTAssertTrue(killed.failed)
        XCTAssertEqual(killed.failureReason, breach)

        let session = try XCTUnwrap(f.sessions.get("w1"))
        XCTAssertEqual(session.state, .failed)
        XCTAssertEqual(session.stopReason, breach)
        XCTAssertNotNil(session.endedAt)
    }

    func testVanishedSessionReportsAndFlagsTheTask() throws {
        let task = try f.task("t", column: .ready)
        try f.board.assign(taskId: task.id, session: f.session("w1", state: .running))

        let report = try XCTUnwrap(f.board.terminate(sessionId: "w1", cause: .vanished))

        XCTAssertEqual(report.kind, .failed)
        XCTAssertTrue(report.body.contains("Agent Board did not stop it"), report.body)
        XCTAssertEqual(try f.tasks.get(task.id)?.column, .ready)
        XCTAssertTrue(try XCTUnwrap(f.tasks.get(task.id)).failed)
        XCTAssertEqual(try f.sessions.get("w1")?.state, .stopped)
    }

    func testHumanStopReportsWithoutFlaggingTheTaskFailed() throws {
        let task = try f.task("t", column: .ready)
        try f.board.assign(taskId: task.id, session: f.session("w1", state: .running))

        let report = try XCTUnwrap(f.board.terminate(sessionId: "w1", cause: .stoppedByHuman))

        XCTAssertEqual(report.kind, .failed)
        let stopped = try XCTUnwrap(f.tasks.get(task.id))
        XCTAssertEqual(stopped.column, .ready)
        XCTAssertFalse(stopped.failed)
        XCTAssertEqual(try f.sessions.get("w1")?.state, .stopped)
    }

    func testTerminateIsIdempotentForAnAlreadyEndedSession() throws {
        let task = try f.task("t", column: .ready)
        try f.board.assign(taskId: task.id, session: f.session("w1", state: .running))
        try f.board.complete(taskId: task.id, sessionId: "w1", summary: "done")

        XCTAssertNil(try f.board.terminate(sessionId: "w1", cause: .vanished))
        XCTAssertEqual(try pending().map(\.kind), [.complete])
        XCTAssertEqual(try f.tasks.get(task.id)?.column, .review)
    }

    func testTerminateSkipsTheOrchestratorSession() throws {
        try f.sessions.insert(f.session("orch", role: .orchestrator, state: .running))

        XCTAssertNil(try f.board.terminate(sessionId: "orch", cause: .vanished))
        XCTAssertEqual(try pending(), [])
        XCTAssertEqual(try f.sessions.get("orch")?.state, .stopped)
    }

    func testTerminateOfAnUnknownSessionDoesNothing() throws {
        XCTAssertNil(try f.board.terminate(sessionId: "nope", cause: .vanished))
        XCTAssertEqual(try pending(), [])
    }

    // MARK: Reopen, discard, promote

    func testReopenReports() throws {
        let task = try f.task("retry me", column: .review)

        let report = try f.board.reopen(taskId: task.id)

        XCTAssertEqual(report.kind, .decision)
        XCTAssertEqual(report.taskId, task.id)
        XCTAssertTrue(report.body.contains("reopened"), report.body)
        XCTAssertEqual(try f.tasks.get(task.id)?.column, .ready)
    }

    func testDiscardReportsTheIdItRemoved() throws {
        let task = try f.task("never mind", column: .ready)

        let report = try f.board.discard(taskId: task.id)

        XCTAssertEqual(report.kind, .decision)
        XCTAssertNil(report.taskId)
        XCTAssertTrue(report.body.contains(task.id), report.body)
        XCTAssertTrue(report.body.contains("never mind"), report.body)
        XCTAssertNil(try f.tasks.get(task.id))
        XCTAssertEqual(try pending().map(\.id), [report.id])
    }

    func testPromoteReportsTheNewlyReadyIds() throws {
        let proposed = try f.board.propose(
            projectId: f.project.id, title: "Add lint", body: nil, rationale: nil, sessionId: nil, epicId: nil
        )

        XCTAssertEqual(try f.board.promote(taskId: proposed.id).newlyReady, [proposed.id])

        let decision = try XCTUnwrap(pending().last)
        XCTAssertEqual(decision.kind, .decision)
        XCTAssertTrue(decision.body.contains("promoted to ready"), decision.body)
        XCTAssertTrue(decision.body.contains(proposed.id), decision.body)
    }
}
