import AgentBoardBridge
import AgentBoardCore
import AgentBoardServer
import Foundation
import XCTest

final class ArchiveToolTests: XCTestCase {
    private var f: BridgeFixture!

    override func setUpWithError() throws {
        f = try BridgeFixture.make()
    }

    private func archivedTask(_ title: String = "shipped") throws -> BoardTask {
        let task = try f.task(title, column: .done)
        try f.tasks.archive(task.id)
        return try XCTUnwrap(f.tasks.get(task.id, includeArchived: true))
    }

    // MARK: list_tasks

    func testListTasksHidesArchivedByDefaultAndShowsThemWithTheFlag() async throws {
        let live = try f.task("still open", column: .ready)
        let archived = try archivedTask()

        let hidden = try await f.callJSON("list_tasks").arrayValue ?? []
        XCTAssertEqual(hidden.map { $0["id"] }, [.string(live.id)])

        let shown = try await f.callJSON("list_tasks", ["include_archived": .bool(true)]).arrayValue ?? []
        XCTAssertEqual(Set(shown.compactMap { $0["id"]?.stringValue }), [live.id, archived.id])
        let entry = try XCTUnwrap(shown.first { $0["id"] == .string(archived.id) })
        XCTAssertEqual(entry["archived"], .bool(true))
        XCTAssertNotEqual(entry["archived_at"], .null)
    }

    func testListTasksFilteredByDoneColumnStillHidesArchived() async throws {
        let done = try f.task("kept", column: .done)
        _ = try archivedTask()

        let list = try await f.callJSON("list_tasks", ["column": .string("done")]).arrayValue ?? []
        XCTAssertEqual(list.map { $0["id"] }, [.string(done.id)])
    }

    // MARK: get_task

    func testGetTaskReturnsAnArchivedTaskMarkedAsArchived() async throws {
        let archived = try archivedTask("audited later")

        let detail = try await f.callJSON("get_task", ["id": .string(archived.id)])
        XCTAssertEqual(detail["id"], .string(archived.id))
        XCTAssertEqual(detail["title"], .string("audited later"))
        XCTAssertEqual(detail["archived"], .bool(true))
        XCTAssertEqual(detail["archived_at"], .number(Double(try XCTUnwrap(archived.archivedAt))))
    }

    func testGetTaskOnALiveTaskReportsNotArchived() async throws {
        let live = try f.task("open", column: .ready)
        let detail = try await f.callJSON("get_task", ["id": .string(live.id)])
        XCTAssertEqual(detail["archived"], .bool(false))
        XCTAssertEqual(detail["archived_at"], .null)
    }

    // MARK: archive_task / unarchive_task

    func testArchiveTaskHidesADoneTaskAndUnarchiveBringsItBack() async throws {
        let task = try f.task("shipped", column: .done)

        _ = try await f.call("archive_task", ["task_id": .string(task.id)])
        XCTAssertNotNil(try f.tasks.get(task.id, includeArchived: true)?.archivedAt)
        let hidden = try await f.callJSON("list_tasks").arrayValue ?? []
        XCTAssertEqual(hidden, [])

        _ = try await f.call("unarchive_task", ["task_id": .string(task.id)])
        XCTAssertNil(try f.tasks.get(task.id, includeArchived: true)?.archivedAt)
        let list = try await f.callJSON("list_tasks").arrayValue ?? []
        XCTAssertEqual(list.map { $0["id"] }, [.string(task.id)])
    }

    func testArchiveTaskRefusesATaskThatIsNotDone() async throws {
        let task = try f.task("in flight", column: .ready)
        await XCTAssertToolError(try await f.call("archive_task", ["task_id": .string(task.id)]), containing: "only done tasks")
        XCTAssertNil(try f.tasks.get(task.id)?.archivedAt)
    }

    func testArchiveAndUnarchiveAreNotInWorkerScope() async throws {
        let archived = try archivedTask()
        let mine = try f.task("in flight", column: .running)
        try f.session("w1", taskId: mine.id)
        let worker = f.workerIdentity(sessionId: "w1", taskId: mine.id)

        let workerTools = await f.scoped.tools(for: worker).map(\.name)
        XCTAssertFalse(workerTools.contains("archive_task"))
        XCTAssertFalse(workerTools.contains("unarchive_task"))

        let orchestratorTools = await f.scoped.tools(for: f.orchestratorIdentity).map(\.name)
        XCTAssertTrue(orchestratorTools.contains("archive_task"))
        XCTAssertTrue(orchestratorTools.contains("unarchive_task"))

        await XCTAssertToolError(
            try await f.call("archive_task", ["task_id": .string(mine.id)], as: worker),
            containing: "Unknown tool"
        )
        await XCTAssertToolError(
            try await f.call("unarchive_task", ["task_id": .string(archived.id)], as: worker),
            containing: "Unknown tool"
        )
        XCTAssertNil(try f.tasks.get(mine.id, includeArchived: true)?.archivedAt)
        XCTAssertNotNil(try f.tasks.get(archived.id, includeArchived: true)?.archivedAt)
    }

    func testArchiveOfAnotherProjectsTaskIsRefused() async throws {
        let other = try f.otherProject()
        let foreign = try f.task("theirs", column: .done, in: other.id)
        await XCTAssertToolError(try await f.call("archive_task", ["task_id": .string(foreign.id)]), containing: "not in this project")
    }

    // MARK: Editing an archived task

    func testMovingAnArchivedTaskOutOfDoneUnarchivesIt() async throws {
        let task = try archivedTask("reopened")

        let result = try await f.call("move_task", ["id": .string(task.id), "column": .string("ready")])
        XCTAssertFalse(result.isError)

        let moved = try XCTUnwrap(f.tasks.get(task.id, includeArchived: true))
        XCTAssertEqual(moved.column, .ready)
        XCTAssertNil(moved.archivedAt)

        let list = try await f.callJSON("list_tasks").arrayValue ?? []
        XCTAssertEqual(list.map { $0["id"] }, [.string(task.id)])
    }

    func testUpdateTaskAndSetDepsWorkOnAnArchivedTaskWithoutUnarchivingIt() async throws {
        let dep = try f.task("dep", column: .ready)
        let task = try archivedTask()

        _ = try await f.call("update_task", ["id": .string(task.id), "title": .string("renamed")])
        _ = try await f.call("set_deps", ["task_id": .string(task.id), "depends_on": .array([.string(dep.id)])])

        let edited = try XCTUnwrap(f.tasks.get(task.id, includeArchived: true))
        XCTAssertEqual(edited.title, "renamed")
        XCTAssertEqual(edited.column, .done, "an archived task is hidden, not frozen, and stays where it was")
        XCTAssertNotNil(edited.archivedAt)
        XCTAssertEqual(try f.tasks.deps(of: task.id), [dep.id])
        let visible = try await f.callJSON("list_tasks").arrayValue ?? []
        XCTAssertEqual(visible.map { $0["id"] }, [.string(dep.id)])
    }

    // MARK: Workers

    func testWorkerGetMyTaskIsUnaffectedByArchiving() async throws {
        let task = try f.task("in flight", column: .running)
        try f.session("w1", taskId: task.id)
        let worker = f.workerIdentity(sessionId: "w1", taskId: task.id)

        await XCTAssertToolError(
            try await f.call("archive_task", ["task_id": .string(task.id)]),
            containing: "only done tasks"
        )

        let mine = try await f.callJSON("get_my_task", as: worker)
        XCTAssertEqual(mine["id"], .string(task.id))
        XCTAssertEqual(mine["column"], .string("running"))
        XCTAssertNil(try f.tasks.get(task.id, includeArchived: true)?.archivedAt)
    }
}
