import AgentBoardCore
import XCTest
@testable import AgentBoard

/// Closing an epic is a board state change. These run against the fixture's real git repository so
/// "no branch is deleted" is checked against git rather than against the promise in the dialog.
@MainActor
final class EpicCloseTests: XCTestCase {
    private var f: SupervisorFixture!

    override func setUp() async throws {
        f = try SupervisorFixture.make(gitRepo: true)
    }

    override func tearDown() async throws {
        await f.cleanUp()
        f = nil
    }

    func testClosingAsDoneKeepsTheEpicBranchAndEveryTaskBranch() async throws {
        let ready = try f.epicReadyForIntegration(["One", "Two"])
        let branches = [ready.epic.branch] + ready.tasks.map { "agentboard/\($0.id)" }
        let headsBefore = try branches.map { try f.git(["rev-parse", $0]) }

        try await f.supervisor.closeEpic(epicId: ready.epic.id, as: .done)

        XCTAssertEqual(try EpicStore(f.db).get(ready.epic.id)?.state, .done)
        XCTAssertEqual(try branches.map { try f.git(["rev-parse", $0]) }, headsBefore, "closing moved or deleted a branch")
    }

    func testRefusedWhileAWorkerIsRunningAndTheWorkerIsLeftAlone() async throws {
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
}
