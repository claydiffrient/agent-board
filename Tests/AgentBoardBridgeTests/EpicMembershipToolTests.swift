import AgentBoardBridge
import AgentBoardCore
import AgentBoardServer
import Foundation
import XCTest

final class EpicMembershipToolTests: XCTestCase {
    private var f: BridgeFixture!

    override func setUpWithError() throws {
        f = try BridgeFixture.make()
    }

    // MARK: create_task epic_id

    func testCreateTaskIntoExistingEpic() async throws {
        let epic = try f.epic("Terminal access")
        let result = try await f.callJSON("create_task", [
            "title": .string("Wire the PTY"), "epic_id": .string(epic.id),
        ])
        let id = try XCTUnwrap(result["id"]?.stringValue)

        XCTAssertEqual(result["epic_id"], .string(epic.id))
        XCTAssertEqual(try f.tasks.get(id)?.epicId, epic.id)
        XCTAssertEqual(try f.tasks.list(projectId: f.project.id, epicId: epic.id).map(\.id), [id])
    }

    func testCreateTaskWithForeignOrUnknownEpicRefused() async throws {
        let other = try f.otherProject()
        let foreign = try f.epic("Theirs", in: other.id)

        await XCTAssertToolError(
            try await f.call("create_task", ["title": .string("x"), "epic_id": .string(foreign.id)]),
            containing: "not in this project"
        )
        await XCTAssertToolError(
            try await f.call("create_task", ["title": .string("x"), "epic_id": .string("nope")]),
            containing: "not in this project"
        )
        XCTAssertEqual(try f.tasks.list(projectId: f.project.id).count, 0, "a refused create must not leave a task behind")
    }

    func testCreateTaskIntoDoneEpicRefused() async throws {
        let epic = try f.epic("Shipped", state: .done)
        await XCTAssertToolError(
            try await f.call("create_task", ["title": .string("late arrival"), "epic_id": .string(epic.id)]),
            containing: "is done"
        )
        XCTAssertEqual(try f.tasks.list(projectId: f.project.id).count, 0)
    }

    // MARK: set_epic

    func testSetEpicMovesUnspawnedTaskAndBothEpicsReportNewCounts() async throws {
        let source = try f.epic("Source")
        let destination = try f.epic("Destination")
        let finished = try f.task("already done", column: .done, epicId: source.id)
        let mover = try f.task("still to do", column: .ready, epicId: source.id)

        let result = try await f.call("set_epic", ["task_id": .string(mover.id), "epic_id": .string(destination.id)])
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.text.contains(destination.id), result.text)
        XCTAssertTrue(result.text.contains(source.id), result.text)
        XCTAssertEqual(try f.tasks.get(mover.id)?.epicId, destination.id)
        XCTAssertEqual(try f.tasks.get(finished.id)?.epicId, source.id)

        let sourceAfter = try await f.callJSON("get_epic", ["id": .string(source.id)])
        XCTAssertEqual(sourceAfter["done_tasks"], .number(1))
        XCTAssertEqual(sourceAfter["total_tasks"], .number(1))
        XCTAssertEqual(sourceAfter["ready_for_integration"], .bool(true))

        let destinationAfter = try await f.callJSON("get_epic", ["id": .string(destination.id)])
        XCTAssertEqual(destinationAfter["done_tasks"], .number(0))
        XCTAssertEqual(destinationAfter["total_tasks"], .number(1))
        XCTAssertEqual(destinationAfter["ready_for_integration"], .bool(false))
    }

    func testSetEpicDetachesTaskWhenEpicIdOmitted() async throws {
        let epic = try f.epic("Source")
        let task = try f.task("t", column: .ready, epicId: epic.id)

        let result = try await f.call("set_epic", ["task_id": .string(task.id)])
        XCTAssertFalse(result.isError)
        XCTAssertNil(try f.tasks.get(task.id)?.epicId)

        let after = try await f.callJSON("get_epic", ["id": .string(epic.id)])
        XCTAssertEqual(after["total_tasks"], .number(0))
        XCTAssertEqual(after["ready_for_integration"], .bool(false), "an empty epic is not ready to integrate")
    }

    func testSetEpicRefusesSpawnedTaskAndNamesItsBranch() async throws {
        let source = try f.epic("Source")
        let destination = try f.epic("Destination")
        let task = try f.task("spawned once", column: .review, epicId: source.id)
        _ = try f.workerSession("s1", taskId: task.id, state: .completed)

        await XCTAssertToolError(
            try await f.call("set_epic", ["task_id": .string(task.id), "epic_id": .string(destination.id)]),
            containing: TaskStore.branchName(for: task.id)
        )
        await XCTAssertToolError(
            try await f.call("set_epic", ["task_id": .string(task.id)]),
            containing: "already been spawned"
        )
        XCTAssertEqual(try f.tasks.get(task.id)?.epicId, source.id)
    }

    func testSetEpicRefusesDoneDestinationEpic() async throws {
        let finished = try f.epic("Shipped", state: .done)
        try f.task("its only task", column: .done, epicId: finished.id)
        let task = try f.task("loose end", column: .ready)

        await XCTAssertToolError(
            try await f.call("set_epic", ["task_id": .string(task.id), "epic_id": .string(finished.id)]),
            containing: "is done"
        )
        XCTAssertNil(try f.tasks.get(task.id)?.epicId)
        let epicAfter = try await f.callJSON("get_epic", ["id": .string(finished.id)])
        XCTAssertEqual(epicAfter["total_tasks"], .number(1))
    }

    func testSetEpicRefusesForeignEpicAndForeignTask() async throws {
        let other = try f.otherProject()
        let foreignEpic = try f.epic("Theirs", in: other.id)
        let foreignTask = try f.task("theirs", in: other.id)
        let task = try f.task("ours")

        await XCTAssertToolError(
            try await f.call("set_epic", ["task_id": .string(task.id), "epic_id": .string(foreignEpic.id)]),
            containing: "not in this project"
        )
        await XCTAssertToolError(
            try await f.call("set_epic", ["task_id": .string(foreignTask.id)]),
            containing: "not in this project"
        )
        XCTAssertNil(try f.tasks.get(task.id)?.epicId)
    }

    func testSetEpicLeavesDependenciesAlone() async throws {
        let epic = try f.epic("Destination")
        let dep = try f.task("first", column: .ready)
        let task = try f.task("second")
        try f.tasks.setDeps(task.id, dependsOn: [dep.id])

        _ = try await f.call("set_epic", ["task_id": .string(task.id), "epic_id": .string(epic.id)])

        XCTAssertEqual(try f.tasks.deps(of: task.id), [dep.id])
        XCTAssertEqual(try f.tasks.get(task.id)?.column, .backlog, "the unmet dependency still holds it in backlog")
    }

    func testSetEpicIsIdempotent() async throws {
        let epic = try f.epic("Destination")
        let task = try f.task("t", epicId: epic.id)

        let result = try await f.call("set_epic", ["task_id": .string(task.id), "epic_id": .string(epic.id)])
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.text.contains("nothing changed"), result.text)
        XCTAssertEqual(try f.tasks.get(task.id)?.epicId, epic.id)
    }
}
