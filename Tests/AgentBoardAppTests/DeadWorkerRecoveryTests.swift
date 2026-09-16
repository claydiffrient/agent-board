import AgentBoardBridge
import AgentBoardCore
import AgentBoardRuntime
import AgentBoardServer
import Foundation
import XCTest
@testable import AgentBoard

/// Three workers died on 2026-09-14/15 and the board mishandled all three: one had its finished,
/// committed branch thrown back to `ready`, and one sat in `running` with no session and no report
/// until a human moved it by hand. Both paths are driven here against a real git repository.
@MainActor
final class DeadWorkerRecoveryTests: XCTestCase {
    private var f: SupervisorFixture!

    override func setUp() async throws {
        f = try SupervisorFixture.make(gitRepo: true)
    }

    override func tearDown() async throws {
        f.cleanUp()
        f = nil
    }

    private func runningTask(_ title: String, state: SessionState = .running) throws -> (task: BoardTask, session: AgentSession) {
        let task = try f.tasks.create(
            projectId: f.project.id, title: title, body: nil, acceptance: nil, priority: nil,
            column: .running, origin: .human, epicId: nil
        )
        return (task, try f.worktreeWorker(task: task, state: state))
    }

    private func reports(_ taskId: String) throws -> [Report] {
        try f.reports.unconsumed(projectId: f.project.id).filter { $0.taskId == taskId }
    }

    // MARK: Defect 1 — a dead worker's commits are not thrown back to ready

    func testAVanishedWorkerWithCommitsGoesToReviewWithItsCommitCount() async throws {
        let (task, session) = try runningTask("add the worktreeStrategy setting")
        try f.commitInto(try XCTUnwrap(session.worktreePath))

        await f.supervisor.reconcile(projectId: f.project.id)

        XCTAssertEqual(try f.tasks.get(task.id)?.column, .review, "a finished branch was thrown back to ready")
        let body = try XCTUnwrap(reports(task.id).first).body
        XCTAssertTrue(body.contains("1 commit "), body)
        XCTAssertTrue(body.contains("agentboard/\(task.id)"), body)
        XCTAssertTrue(body.contains("unverified, not finished"), body)
    }

    func testAVanishedWorkerWithNoCommitsGoesBackToReady() async throws {
        let (task, _) = try runningTask("never got started")

        await f.supervisor.reconcile(projectId: f.project.id)

        XCTAssertEqual(try f.tasks.get(task.id)?.column, .ready)
        let body = try XCTUnwrap(reports(task.id).first).body
        XCTAssertTrue(body.contains("no commits its base does not"), body)
        XCTAssertTrue(body.contains("back in ready; dispatch it again"), body)
    }

    func testUncommittedEditsAreNamedWithoutClaimingTheBranchHasWork() async throws {
        let (task, session) = try runningTask("died mid-edit")
        try "half a thought\n".write(
            to: URL(fileURLWithPath: try XCTUnwrap(session.worktreePath)).appendingPathComponent("draft.txt"),
            atomically: true, encoding: .utf8
        )

        await f.supervisor.reconcile(projectId: f.project.id)

        XCTAssertEqual(try f.tasks.get(task.id)?.column, .ready, "uncommitted edits are not committed work")
        XCTAssertTrue(try XCTUnwrap(reports(task.id).first).body.contains("uncommitted edits"))
    }

    // MARK: Defect 2 — nothing strands in running, whatever path the death took

    /// The root cause: `SessionEnd` arrives over the hook server while the stop is still in flight,
    /// writes `stopped`, and the terminate that follows used to read that as "already handled" and
    /// leave the task in `running` forever. `bc66e063` is exactly this.
    func testSessionEndBeatingTheStopDoesNotStrandTheTask() async throws {
        let (task, session) = try runningTask("notify for approvals and blocked workers")
        let hooks = StoreHookSink(db: f.db, events: LateBoundSink())
        _ = await hooks.handle(
            HookEvent(name: "SessionEnd", sessionId: session.sessionId, rawJSON: "{}"),
            identity: TokenIdentity(
                token: "w", scope: .worker, projectId: f.project.id,
                sessionId: session.sessionId, taskId: task.id
            )
        )
        XCTAssertEqual(try f.sessions.get(session.sessionId)?.state, .stopped)

        try await f.supervisor.stop(sessionId: session.sessionId)

        XCTAssertNotEqual(try f.tasks.get(task.id)?.column, .running, "the task stranded in running")
        XCTAssertFalse(try reports(task.id).isEmpty, "a dead session left no report of any kind")
    }

    /// The reaper that did not fire for `bc66e063`: `reconcile` skips an inactive row, so nothing
    /// looked at its task again. The sweep is what makes the outcome unconditional.
    func testReconcileFreesATaskWhoseSessionRowIsAlreadyInactive() async throws {
        let (task, session) = try runningTask("stranded", state: .stopped)
        try f.commitInto(try XCTUnwrap(session.worktreePath))

        await f.supervisor.reconcile(projectId: f.project.id)

        XCTAssertEqual(try f.tasks.get(task.id)?.column, .review)
        XCTAssertTrue(try XCTUnwrap(reports(task.id).first).body.contains("stranded in running"))
    }

    func testReconcileFreesATaskWithNoSessionRowAtAll() async throws {
        let task = try f.tasks.create(
            projectId: f.project.id, title: "no session ever", body: nil, acceptance: nil, priority: nil,
            column: .running, origin: .human, epicId: nil
        )

        await f.supervisor.reconcile(projectId: f.project.id)

        XCTAssertEqual(try f.tasks.get(task.id)?.column, .ready)
        XCTAssertTrue(try XCTUnwrap(reports(task.id).first).body.contains("No session was ever recorded"))
    }

    /// Three sessions died within forty minutes of each other; one sweep has to clear all of them.
    func testOneReconcileClearsEveryStrandedTaskAtOnce() async throws {
        let stranded = try (0..<3).map { try runningTask("worker \($0)", state: .stopped) }
        try f.commitInto(try XCTUnwrap(stranded[1].session.worktreePath))

        await f.supervisor.reconcile(projectId: f.project.id)

        let columns = try stranded.map { try f.tasks.get($0.task.id)?.column }
        XCTAssertEqual(columns, [.ready, .review, .ready])
    }

    /// `reconcile` only runs while the Status screen is open. The metering tick has no such
    /// condition, so a strand is cleared whether or not anybody is looking at the board.
    func testTheMeteringTickClearsAStrandWithoutReconcile() async throws {
        let (task, session) = try runningTask("nobody is watching", state: .stopped)
        try f.commitInto(try XCTUnwrap(session.worktreePath))

        await f.supervisor.meterTick()

        XCTAssertEqual(try f.tasks.get(task.id)?.column, .review)
        XCTAssertTrue(try XCTUnwrap(reports(task.id).first).body.contains("1 commit "))
    }

    func testTheSweepIsIdempotent() async throws {
        let (task, _) = try runningTask("stranded twice", state: .stopped)

        await f.supervisor.recoverStrandedTasks(projectId: f.project.id)
        await f.supervisor.recoverStrandedTasks(projectId: f.project.id)

        XCTAssertEqual(try f.tasks.get(task.id)?.column, .ready)
        XCTAssertEqual(try reports(task.id).count, 1, "the sweep reported the same strand twice")
    }

    func testReconcileLeavesALiveWorkerAlone() async throws {
        let (task, _) = try runningTask("still working")
        let live = try XCTUnwrap(f.sessions.forTask(task.id).first)
        await f.runtime.listing([AgentInfo(
            id: live.shortId, cwd: live.cwd, kind: "agent", sessionId: live.sessionId,
            state: "running", status: "running"
        )])

        await f.supervisor.reconcile(projectId: f.project.id)

        XCTAssertEqual(try f.tasks.get(task.id)?.column, .running)
        XCTAssertTrue(try reports(task.id).isEmpty)
    }
}
