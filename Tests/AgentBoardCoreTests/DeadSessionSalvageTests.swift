import Foundation
import XCTest
@testable import AgentBoardCore

/// A worker that dies without reporting must not cost its task the commits it already made, and
/// must never leave the task in `running`, where `spawn_worker` refuses it and nothing else looks.
final class DeadSessionSalvageTests: XCTestCase {
    private var f: Fixture!

    override func setUpWithError() throws {
        f = try Fixture.make()
    }

    private func pending() throws -> [Report] {
        try f.reports.unconsumed(projectId: f.project.id)
    }

    @discardableResult
    private func running(_ title: String, session id: String = "w1") throws -> BoardTask {
        let task = try f.task(title, column: .ready)
        try f.board.assign(taskId: task.id, session: f.session(id))
        try f.sessions.setState(id, .running)
        return task
    }

    // MARK: Defect 1 — committed work must not be thrown back to ready

    func testTerminateRoutesCommittedWorkToReviewAndNamesTheCommitCount() throws {
        let task = try running("add the worktreeStrategy setting")
        let salvage = BranchSalvage(branch: "agentboard/\(task.id)", commitsAheadOfBase: 3)

        let report = try XCTUnwrap(f.board.terminate(sessionId: "w1", cause: .capBreach("idle cap reached"), salvage: salvage))

        XCTAssertEqual(try f.tasks.get(task.id)?.column, .review, "committed work went back to ready as if nothing happened")
        XCTAssertTrue(report.body.contains("3 commits"), report.body)
        XCTAssertTrue(report.body.contains("agentboard/\(task.id)"), report.body)
        XCTAssertFalse(report.body.contains("back in ready"), report.body)
    }

    /// The report may not read as a completion: no worker vouched for the branch and nothing built it.
    func testTheSalvageReportDoesNotClaimTheWorkIsFinished() throws {
        let task = try running("add the worktreeStrategy setting")
        let salvage = BranchSalvage(branch: "agentboard/\(task.id)", commitsAheadOfBase: 1, uncommittedChanges: true)

        let report = try XCTUnwrap(f.board.terminate(sessionId: "w1", cause: .vanished, salvage: salvage))

        XCTAssertEqual(report.kind, .failed)
        XCTAssertTrue(report.body.contains("1 commit "), report.body)
        XCTAssertTrue(report.body.contains("unverified, not finished"), report.body)
        XCTAssertTrue(report.body.contains("uncommitted edits"), report.body)
        XCTAssertTrue(try XCTUnwrap(f.tasks.get(task.id)).failed, "a task nobody reported on must still read as failed")
    }

    func testTerminateReturnsAnEmptyBranchToReady() throws {
        let task = try running("nothing got written")
        let salvage = BranchSalvage(branch: "agentboard/\(task.id)", commitsAheadOfBase: 0)

        let report = try XCTUnwrap(f.board.terminate(sessionId: "w1", cause: .capBreach("idle cap reached"), salvage: salvage))

        XCTAssertEqual(try f.tasks.get(task.id)?.column, .ready)
        XCTAssertTrue(report.body.contains("back in ready; dispatch it again"), report.body)
        XCTAssertTrue(report.body.contains("no commits its base does not"), report.body)
    }

    /// Salvage that could not be read claims nothing, and the task lands where it always did.
    func testTerminateWithoutSalvageIsUnchanged() throws {
        let task = try running("branch could not be read")

        let report = try XCTUnwrap(f.board.terminate(sessionId: "w1", cause: .vanished))

        XCTAssertEqual(try f.tasks.get(task.id)?.column, .ready)
        XCTAssertFalse(report.body.contains("commits"), report.body)
    }

    /// A wound-down worker answered for itself and its task carries a resume note; commits on the
    /// branch do not get to re-route that path.
    func testAWoundDownWorkerStillGoesBackToReady() throws {
        let task = try running("wound down")
        let salvage = BranchSalvage(branch: "agentboard/\(task.id)", commitsAheadOfBase: 2)

        let report = try XCTUnwrap(f.board.terminate(
            sessionId: "w1", cause: .shutdownAcknowledged(note: "committed at 64aa64d"), salvage: salvage
        ))

        XCTAssertEqual(try f.tasks.get(task.id)?.column, .ready)
        XCTAssertTrue(report.body.contains("2 commits"), report.body)
    }

    // MARK: Defect 2 — nothing may strand in running

    /// The root cause of the stranded task: `SessionEnd` writes `stopped` while the cap kill is
    /// still awaiting the process, and `terminate` used to read that as "already handled".
    func testTerminateStillMovesTheTaskWhenSessionEndAlreadyStoppedTheRow() throws {
        let task = try running("notify for approvals and blocked workers")
        try f.sessions.setState("w1", .stopped, endedAt: .nowMillis)

        let report = try XCTUnwrap(f.board.terminate(sessionId: "w1", cause: .capBreach("idle cap reached")))

        XCTAssertEqual(try f.tasks.get(task.id)?.column, .ready, "the task stranded in running")
        XCTAssertEqual(report.kind, .failed)
        XCTAssertEqual(try f.sessions.get("w1")?.state, .stopped, "the recorded end must not be rewritten")
    }

    func testTerminateOnAStoppedRowWhoseTaskMovedOnStaysSilent() throws {
        let task = try running("already reviewed")
        try f.sessions.setState("w1", .stopped, endedAt: .nowMillis)
        try f.tasks.move(task.id, to: .review)

        XCTAssertNil(try f.board.terminate(sessionId: "w1", cause: .vanished))
    }

    func testStrandedRunningTasksFindsATaskNoActiveSessionOwns() throws {
        let stranded = try running("stranded", session: "w1")
        try f.sessions.setState("w1", .stopped, endedAt: .nowMillis)
        try running("still working", session: "w2")
        let neverDispatched = try f.task("no session at all", column: .running)

        let found = try f.board.strandedRunningTasks(projectId: f.project.id).map(\.id)

        XCTAssertEqual(Set(found), [stranded.id, neverDispatched.id])
    }

    /// A worker whose worktree is still being prepared holds its task; the sweep must not take it.
    func testStrandedRunningTasksLeavesASetupSessionAlone() throws {
        let task = try f.task("being set up", column: .ready)
        try f.board.assign(taskId: task.id, session: f.session("w1"))

        XCTAssertEqual(try f.sessions.get("w1")?.state, .setup)
        XCTAssertEqual(try f.board.strandedRunningTasks(projectId: f.project.id), [])
    }

    /// `bc66e063` had no reachable session at all: nothing to terminate, so only this path can free it.
    func testRecoverStrandedMovesATaskWithNoSessionRowOutOfRunning() throws {
        let task = try f.task("notify for approvals and blocked workers", column: .running)

        let report = try XCTUnwrap(f.board.recoverStranded(taskId: task.id))

        XCTAssertEqual(try f.tasks.get(task.id)?.column, .ready)
        XCTAssertEqual(report.kind, .failed)
        XCTAssertTrue(report.body.contains("No session was ever recorded"), report.body)
        XCTAssertTrue(try XCTUnwrap(f.tasks.get(task.id)).failed)
    }

    func testRecoverStrandedNamesTheLastSessionAndSalvagesItsBranch() throws {
        let task = try running("stranded with work")
        try f.sessions.setState("w1", .stopped, endedAt: .nowMillis)

        let report = try XCTUnwrap(f.board.recoverStranded(
            taskId: task.id, salvage: BranchSalvage(branch: "agentboard/\(task.id)", commitsAheadOfBase: 4)
        ))

        XCTAssertEqual(try f.tasks.get(task.id)?.column, .review)
        XCTAssertTrue(report.body.contains("4 commits"), report.body)
        XCTAssertEqual(report.sessionId, "w1")
    }

    func testRecoverStrandedLeavesATaskThatStillHasALiveSession() throws {
        let task = try running("still working")

        XCTAssertNil(try f.board.recoverStranded(taskId: task.id))
        XCTAssertEqual(try f.tasks.get(task.id)?.column, .running)
    }

    func testRecoverStrandedLeavesATaskThatIsNoLongerRunning() throws {
        let task = try f.task("done already", column: .review)

        XCTAssertNil(try f.board.recoverStranded(taskId: task.id))
        XCTAssertEqual(try f.tasks.get(task.id)?.column, .review)
    }
}
