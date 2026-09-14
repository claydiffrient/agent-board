import AgentBoardCore
import XCTest
@testable import AgentBoard

/// Closing an epic is a board state change. These run against the fixture's real git repository so
/// "no branch is deleted" is checked against git rather than against the promise in the dialog.
@MainActor
final class EpicCloseTests: XCTestCase {
    func testClosingAsDoneKeepsTheEpicBranchAndEveryTaskBranch() async throws {
        let f = try SupervisorFixture.make(gitRepo: true)
        defer { f.cleanUp() }
        let ready = try f.epicReadyForIntegration(["One", "Two"])
        let branches = [ready.epic.branch] + ready.tasks.map { "agentboard/\($0.id)" }
        let headsBefore = try branches.map { try f.git(["rev-parse", $0]) }

        try await f.supervisor.closeEpic(epicId: ready.epic.id, as: .done)

        XCTAssertEqual(try EpicStore(f.db).get(ready.epic.id)?.state, .done)
        XCTAssertEqual(try branches.map { try f.git(["rev-parse", $0]) }, headsBefore, "closing moved or deleted a branch")
    }

    func testAbandoningKeepsEveryBranchToo() async throws {
        let f = try SupervisorFixture.make(gitRepo: true)
        defer { f.cleanUp() }
        let ready = try f.epicReadyForIntegration(["One"])
        let taskBranch = "agentboard/\(ready.tasks[0].id)"

        try await f.supervisor.closeEpic(epicId: ready.epic.id, as: .abandoned)

        XCTAssertEqual(try EpicStore(f.db).get(ready.epic.id)?.state, .abandoned)
        XCTAssertNoThrow(try f.git(["rev-parse", "--verify", ready.epic.branch]))
        XCTAssertNoThrow(try f.git(["rev-parse", "--verify", taskBranch]))
    }

    /// An unfinished task's worktree is what would be lost if closing tore anything down.
    func testAnUnfinishedTasksWorktreeSurvivesTheClose() async throws {
        let f = try SupervisorFixture.make(gitRepo: true)
        defer { f.cleanUp() }
        let (epic, created) = try Board(f.db).createEpic(
            projectId: f.project.id, title: "Ship it", goal: nil,
            tasks: [NewEpicTask(title: "One"), NewEpicTask(title: "Two")]
        )
        try TaskStore(f.db).move(created[0].id, to: .done)
        let stalled = try f.worktreeWorker(task: created[1], state: .stopped)
        let worktreePath = try XCTUnwrap(stalled.worktreePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktreePath))

        try await f.supervisor.closeEpic(epicId: epic.id, as: .done)

        XCTAssertTrue(FileManager.default.fileExists(atPath: worktreePath), "closing removed a worktree")
        XCTAssertNoThrow(try f.git(["rev-parse", "--verify", "agentboard/\(created[1].id)"]))
        XCTAssertEqual(try TaskStore(f.db).get(created[1].id)?.epicId, epic.id)
        XCTAssertEqual(try TaskStore(f.db).get(created[1].id)?.column, .ready)
    }

    func testRefusedWhileAWorkerIsRunningAndTheWorkerIsLeftAlone() async throws {
        let f = try SupervisorFixture.make(gitRepo: true)
        defer { f.cleanUp() }
        let (epic, created) = try Board(f.db).createEpic(
            projectId: f.project.id, title: "Ship it", goal: nil, tasks: [NewEpicTask(title: "One")]
        )
        let live = try f.worktreeWorker(task: created[0], state: .running)

        do {
            try await f.supervisor.closeEpic(epicId: epic.id, as: .done)
            XCTFail("closing succeeded with a worker running in the epic")
        } catch {
            XCTAssertTrue(errorText(error).contains("still running in this epic"), errorText(error))
        }

        XCTAssertEqual(try EpicStore(f.db).get(epic.id)?.state, .planning)
        XCTAssertEqual(try f.sessions.get(live.sessionId)?.state, .running, "the refused close touched the worker")
        let stopped = await f.runtime.stopped
        XCTAssertTrue(stopped.isEmpty, "the refused close stopped a worker instead of refusing")
    }

    func testTheHumanCanCloseOnceTheWorkerIsStopped() async throws {
        let f = try SupervisorFixture.make(gitRepo: true)
        defer { f.cleanUp() }
        let (epic, created) = try Board(f.db).createEpic(
            projectId: f.project.id, title: "Ship it", goal: nil, tasks: [NewEpicTask(title: "One")]
        )
        let live = try f.worktreeWorker(task: created[0], state: .running)

        try await f.supervisor.stop(sessionId: live.sessionId)
        try await f.supervisor.closeEpic(epicId: epic.id, as: .abandoned)

        XCTAssertEqual(try EpicStore(f.db).get(epic.id)?.state, .abandoned)
    }

    func testClosingTwiceIntoDifferentStatesIsRefused() async throws {
        let f = try SupervisorFixture.make(gitRepo: true)
        defer { f.cleanUp() }
        let (epic, _) = try Board(f.db).createEpic(
            projectId: f.project.id, title: "Ship it", goal: nil, tasks: []
        )
        try await f.supervisor.closeEpic(epicId: epic.id, as: .done)
        do {
            try await f.supervisor.closeEpic(epicId: epic.id, as: .abandoned)
            XCTFail("a closed epic was closed again")
        } catch {
            XCTAssertTrue(errorText(error).contains("already done, and closing is one way"), errorText(error))
        }
        XCTAssertEqual(try EpicStore(f.db).get(epic.id)?.state, .done)
    }

    func testTheClosureDialogPreflightNamesTheLeftoversAndTheGuarantees() async throws {
        let f = try SupervisorFixture.make(gitRepo: true)
        defer { f.cleanUp() }
        let (epic, created) = try Board(f.db).createEpic(
            projectId: f.project.id, title: "Ship it", goal: nil,
            tasks: [NewEpicTask(title: "One"), NewEpicTask(title: "Two")]
        )
        try TaskStore(f.db).move(created[0].id, to: .done)

        let plan = try f.supervisor.epicClosurePlan(epicId: epic.id, as: .done)
        XCTAssertEqual(plan.unfinished.map(\.title), ["Two"])
        XCTAssertFalse(plan.isRefused)
        XCTAssertTrue(plan.message.contains("Every branch and worktree survives"), plan.message)
        XCTAssertTrue(plan.message.contains("1 unfinished task stays exactly where it is"), plan.message)
    }
}
