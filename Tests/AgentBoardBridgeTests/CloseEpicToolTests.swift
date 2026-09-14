import AgentBoardBridge
import AgentBoardCore
import AgentBoardServer
import Foundation
import XCTest

final class CloseEpicToolTests: XCTestCase {
    private var f: BridgeFixture!

    override func setUpWithError() throws {
        f = try BridgeFixture.make()
    }

    func testClosingAsDoneWritesTheStateAndSaysWhatSurvived() async throws {
        let epic = try f.epic("Ship it")
        try f.task("half done", column: .ready, epicId: epic.id)

        let result = try await f.call("close_epic", [
            "epic_id": .string(epic.id), "state": .string("done"),
        ])

        XCTAssertEqual(try EpicStore(f.db).get(epic.id)?.state, .done)
        XCTAssertTrue(result.text.contains(epic.branch), result.text)
        XCTAssertTrue(result.text.contains("Nothing was merged, pushed or deleted"), result.text)
        XCTAssertTrue(result.text.contains("1 unfinished task(s) stay in the epic"), result.text)
    }

    func testAbandoningWritesAbandoned() async throws {
        let epic = try f.epic("Wrong idea")
        _ = try await f.call("close_epic", ["epic_id": .string(epic.id), "state": .string("abandoned")])
        XCTAssertEqual(try EpicStore(f.db).get(epic.id)?.state, .abandoned)
    }

    func testUnfinishedTasksAreNotDeletedArchivedOrMovedOut() async throws {
        let epic = try f.epic("Ship it")
        let ready = try f.task("still to do", column: .ready, epicId: epic.id)
        let review = try f.task("waiting on a human", column: .review, epicId: epic.id)

        _ = try await f.call("close_epic", ["epic_id": .string(epic.id), "state": .string("abandoned")])

        for id in [ready.id, review.id] {
            let task = try XCTUnwrap(try f.tasks.get(id))
            XCTAssertEqual(task.epicId, epic.id, "\(id) was moved out of the epic")
            XCTAssertFalse(task.isArchived, "\(id) was archived")
        }
        XCTAssertEqual(try f.tasks.get(ready.id)?.column, .ready)
        XCTAssertEqual(try f.tasks.get(review.id)?.column, .review)
    }

    func testQueuesADecisionReportForTheOrchestrator() async throws {
        let epic = try f.epic("Ship it")
        try f.task("leftover", column: .backlog, epicId: epic.id)
        _ = try await f.call("close_epic", ["epic_id": .string(epic.id), "state": .string("done")])

        let reports = try f.reports.unconsumed(projectId: f.project.id)
        let decision = try XCTUnwrap(reports.first { $0.kind == .decision })
        XCTAssertTrue(decision.body.contains("Do not plan or dispatch further work into it"), decision.body)
        XCTAssertTrue(decision.body.contains(epic.branch), decision.body)
    }

    // MARK: Guards

    func testRefusedWhileAWorkerIsRunningInTheEpic() async throws {
        let epic = try f.epic("Ship it")
        let task = try f.task("in flight", column: .running, epicId: epic.id)
        try f.session("s1", state: .running, taskId: task.id)

        await XCTAssertToolError(
            try await f.call("close_epic", ["epic_id": .string(epic.id), "state": .string("done")]),
            containing: "still running in this epic"
        )
        XCTAssertEqual(try EpicStore(f.db).get(epic.id)?.state, .active, "a refused close wrote the state anyway")
    }

    func testRefusedForAnAlreadyClosedEpic() async throws {
        let epic = try f.epic("Shipped", state: .done)
        await XCTAssertToolError(
            try await f.call("close_epic", ["epic_id": .string(epic.id), "state": .string("abandoned")]),
            containing: "already done"
        )
        XCTAssertEqual(try EpicStore(f.db).get(epic.id)?.state, .done)
    }

    func testRefusedForAnEpicInAnotherProject() async throws {
        let other = try f.otherProject()
        let foreign = try f.epic("Theirs", in: other.id)
        await XCTAssertToolError(
            try await f.call("close_epic", ["epic_id": .string(foreign.id), "state": .string("done")]),
            containing: "not in this project"
        )
        XCTAssertEqual(try EpicStore(f.db).get(foreign.id)?.state, .active)
    }

    func testUnknownStateIsRefusedAndNamesTheTwoThatWork() async throws {
        let epic = try f.epic("Ship it")
        await XCTAssertToolError(
            try await f.call("close_epic", ["epic_id": .string(epic.id), "state": .string("integrating")]),
            containing: "done, abandoned"
        )
        XCTAssertEqual(try EpicStore(f.db).get(epic.id)?.state, .active)
    }

    // MARK: Scope

    func testAWorkerCannotCloseTheEpicItIsWorkingIn() async throws {
        let epic = try f.epic("Ship it")
        let task = try f.task("mine", column: .running, epicId: epic.id)
        try f.session("w1", state: .running, taskId: task.id)
        let identity = f.workerIdentity(sessionId: "w1", taskId: task.id)

        await XCTAssertToolError(
            try await f.call("close_epic", ["epic_id": .string(epic.id), "state": .string("done")], as: identity),
            containing: "Unknown tool"
        )
        XCTAssertEqual(try EpicStore(f.db).get(epic.id)?.state, .active)

        let worker = await f.scoped.tools(for: identity)
        XCTAssertFalse(worker.map(\.name).contains("close_epic"), "close_epic is in worker scope")
    }

    func testCloseEpicIsInOrchestratorScope() async throws {
        let listed = await f.scoped.tools(for: f.orchestratorIdentity).map(\.name)
        XCTAssertTrue(listed.contains("close_epic"), "close_epic is missing from orchestrator scope")
    }

    // MARK: A closed epic takes no more work

    func testAnAbandonedEpicIsRefusedAsADestination() async throws {
        let epic = try f.epic("Wrong idea")
        _ = try await f.call("close_epic", ["epic_id": .string(epic.id), "state": .string("abandoned")])

        await XCTAssertToolError(
            try await f.call("create_task", ["title": .string("late"), "epic_id": .string(epic.id)]),
            containing: "is abandoned"
        )
        let orphan = try f.task("elsewhere", column: .ready)
        await XCTAssertToolError(
            try await f.call("set_epic", ["task_id": .string(orphan.id), "epic_id": .string(epic.id)]),
            containing: "is abandoned"
        )
    }

    /// The escape hatch the close report names: work left in a closed epic can still be freed.
    func testLeftoverWorkCanStillBeTakenOutOfAClosedEpic() async throws {
        let epic = try f.epic("Ship it")
        let leftover = try f.task("still matters", column: .ready, epicId: epic.id)
        _ = try await f.call("close_epic", ["epic_id": .string(epic.id), "state": .string("done")])

        _ = try await f.call("set_epic", ["task_id": .string(leftover.id)])
        XCTAssertNil(try f.tasks.get(leftover.id)?.epicId)
        XCTAssertEqual(try f.tasks.get(leftover.id)?.column, .ready)
    }
}
