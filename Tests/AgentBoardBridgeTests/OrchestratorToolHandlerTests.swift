import AgentBoardBridge
import AgentBoardCore
import AgentBoardServer
import Foundation
import XCTest

final class OrchestratorToolHandlerTests: XCTestCase {
    private var f: BridgeFixture!

    override func setUpWithError() throws {
        f = try BridgeFixture.make()
    }

    // MARK: Scoped routing

    func testScopedRoutingRendersDifferentToolListsPerScope() async throws {
        let workerTools = await f.scoped.tools(for: f.workerIdentity(sessionId: "s1", taskId: "t1")).map(\.name)
        let orchestratorTools = await f.scoped.tools(for: f.orchestratorIdentity).map(\.name)

        XCTAssertTrue(workerTools.contains("get_my_task"))
        XCTAssertTrue(workerTools.contains("report_complete"))
        XCTAssertFalse(workerTools.contains("spawn_worker"))

        XCTAssertTrue(workerTools.contains("search_notes"))
        XCTAssertTrue(workerTools.contains("create_note"))
        XCTAssertFalse(workerTools.contains("attach_note"))
        XCTAssertFalse(workerTools.contains("pin_note"))

        XCTAssertTrue(orchestratorTools.contains("spawn_worker"))
        XCTAssertTrue(orchestratorTools.contains("attach_note"))
        XCTAssertTrue(orchestratorTools.contains("pin_note"))
        XCTAssertTrue(orchestratorTools.contains("search_notes"))
        XCTAssertTrue(orchestratorTools.contains("list_reports"))
        XCTAssertFalse(orchestratorTools.contains("get_my_task"))
        XCTAssertFalse(orchestratorTools.contains("report_complete"))
        XCTAssertFalse(orchestratorTools.contains("update_status"))
        XCTAssertNotEqual(Set(workerTools), Set(orchestratorTools))
    }

    func testEveryOrchestratorSchemaForbidsAdditionalProperties() async {
        for tool in await f.orchestrator.tools(for: f.orchestratorIdentity) {
            XCTAssertEqual(tool.inputSchema["additionalProperties"], .bool(false), tool.name)
        }
    }

    func testWorkerCallingOrchestratorToolIsUnknown() async throws {
        let task = try f.task("t")
        try f.session("s1", taskId: task.id)
        await XCTAssertToolError(
            try await f.call("spawn_worker", ["task_id": .string(task.id)], as: f.workerIdentity(sessionId: "s1", taskId: task.id)),
            containing: "Unknown tool"
        )
    }

    // MARK: create_task

    func testCreateTaskLandsInBacklogWithOrchestratorOriginAndBecomesReady() async throws {
        let result = try await f.callJSON("create_task", ["title": .string("Build it"), "acceptance": .string("It builds")])
        let id = try XCTUnwrap(result["id"]?.stringValue)
        let task = try XCTUnwrap(f.tasks.get(id))

        XCTAssertEqual(task.origin, .orchestrator)
        XCTAssertEqual(task.acceptance, "It builds")
        XCTAssertEqual(task.column, .ready, "a dep-free backlog task becomes ready on refresh")
        XCTAssertEqual(result["column"], .string("ready"))
    }

    func testCreateTaskWithUnmetDependencyStaysInBacklog() async throws {
        let dep = try f.task("dep")
        let result = try await f.callJSON("create_task", ["title": .string("after"), "depends_on": .array([.string(dep.id)])])
        let id = try XCTUnwrap(result["id"]?.stringValue)

        XCTAssertEqual(try f.tasks.get(id)?.column, .backlog)
        XCTAssertEqual(try f.tasks.deps(of: id), [dep.id])
    }

    func testCreateTaskInRunningOrDoneRefused() async {
        await XCTAssertToolError(try await f.call("create_task", ["title": .string("x"), "column": .string("running")]), containing: "spawn_worker")
        await XCTAssertToolError(try await f.call("create_task", ["title": .string("x"), "column": .string("done")]), containing: "human")
    }

    // MARK: move_task

    func testMoveTaskToRunningRefused() async throws {
        let task = try f.task("t", column: .ready)
        await XCTAssertToolError(try await f.call("move_task", ["id": .string(task.id), "column": .string("running")]), containing: "spawn_worker")
        XCTAssertEqual(try f.tasks.get(task.id)?.column, .ready)
    }

    func testMoveTaskToDoneRefused() async throws {
        let task = try f.task("t", column: .review)
        await XCTAssertToolError(try await f.call("move_task", ["id": .string(task.id), "column": .string("done")]), containing: "human")
        XCTAssertEqual(try f.tasks.get(task.id)?.column, .review)
    }

    func testMoveTaskToReviewSucceeds() async throws {
        let task = try f.task("t", column: .ready)
        let result = try await f.call("move_task", ["id": .string(task.id), "column": .string("review")])
        XCTAssertFalse(result.isError)
        XCTAssertEqual(try f.tasks.get(task.id)?.column, .review)
    }

    // MARK: set_deps

    func testSetDepsRefreshesReadiness() async throws {
        let dep = try f.task("dep")
        let task = try f.task("t", column: .ready)
        _ = try await f.call("set_deps", ["task_id": .string(task.id), "depends_on": .array([.string(dep.id)])])
        XCTAssertEqual(try f.tasks.get(task.id)?.column, .backlog)

        _ = try await f.call("set_deps", ["task_id": .string(task.id), "depends_on": .array([])])
        XCTAssertEqual(try f.tasks.get(task.id)?.column, .ready)
    }

    // MARK: spawn_worker

    func testSpawnWorkerWithAutonomyOffReturnsApprovalTextAndCreatesOnePendingApproval() async throws {
        let task = try f.task("t", column: .ready)
        let first = try await f.call("spawn_worker", ["task_id": .string(task.id)])
        let second = try await f.call("spawn_worker", ["task_id": .string(task.id)])

        XCTAssertTrue(first.text.contains("pending; the human must approve"), first.text)
        XCTAssertTrue(first.text.contains("list_reports"))
        XCTAssertEqual(first.text, second.text)

        let pending = try f.approvals.pending(projectId: f.project.id)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.kind, .spawn)
        XCTAssertEqual(pending.first?.taskId, task.id)
        XCTAssertEqual(pending.first?.requestedBy, "orch-session")
        let spawned = await f.control.spawned
        XCTAssertEqual(spawned, [])
        XCTAssertEqual(try f.tasks.get(task.id)?.column, .ready)
    }

    func testSpawnWorkerWithAutonomyOnCallsControl() async throws {
        try f.setAutonomy(true)
        let task = try f.task("t", column: .ready)
        let result = try await f.call("spawn_worker", ["task_id": .string(task.id)])

        XCTAssertEqual(result.text, "spawned session session-for-\(task.id)")
        let spawned = await f.control.spawned
        XCTAssertEqual(spawned, [task.id])
        XCTAssertEqual(try f.approvals.pending(projectId: f.project.id).count, 0)
    }

    func testSpawnWorkerOnNonReadyTaskIsRefused() async throws {
        try f.setAutonomy(true)
        let task = try f.task("t", column: .backlog)
        await XCTAssertToolError(try await f.call("spawn_worker", ["task_id": .string(task.id)]), containing: "ready")
        let spawned = await f.control.spawned
        XCTAssertEqual(spawned, [])
    }

    func testStopWorkerCallsControl() async throws {
        let task = try f.task("t", column: .running)
        try f.session("w1", taskId: task.id)
        let result = try await f.call("stop_worker", ["session_id": .string("w1")])
        XCTAssertEqual(result.text, "stopped session w1")
        let stopped = await f.control.stopped
        XCTAssertEqual(stopped, ["w1"])
    }

    // MARK: Cross-project scoping

    func testCrossProjectTaskAccessIsToolError() async throws {
        let other = try f.otherProject()
        let foreign = try f.task("foreign", column: .ready, in: other.id)

        await XCTAssertToolError(try await f.call("get_task", ["id": .string(foreign.id)]), containing: "not in this project")
        await XCTAssertToolError(try await f.call("update_task", ["id": .string(foreign.id), "title": .string("x")]), containing: "not in this project")
        await XCTAssertToolError(try await f.call("move_task", ["id": .string(foreign.id), "column": .string("review")]), containing: "not in this project")
        await XCTAssertToolError(try await f.call("spawn_worker", ["task_id": .string(foreign.id)]), containing: "not in this project")
        await XCTAssertToolError(try await f.call("log_progress", ["task_id": .string(foreign.id), "text": .string("x")]), containing: "not in this project")

        let mine = try f.task("mine")
        await XCTAssertToolError(
            try await f.call("set_deps", ["task_id": .string(mine.id), "depends_on": .array([.string(foreign.id)])]),
            containing: "not in this project"
        )
        XCTAssertEqual(try f.tasks.get(foreign.id)?.title, "foreign")
    }

    func testListTasksOnlyShowsThisProject() async throws {
        let other = try f.otherProject()
        try f.task("foreign", in: other.id)
        let mine = try f.task("mine")
        let list = try await f.callJSON("list_tasks").arrayValue ?? []
        XCTAssertEqual(list.map { $0["id"] }, [.string(mine.id)])
    }

    // MARK: Reports

    func testListReportsConsumes() async throws {
        let task = try f.task("t", column: .running)
        try f.session("w1", taskId: task.id)
        try f.board.complete(taskId: task.id, sessionId: "w1", summary: "done")

        let first = try await f.callJSON("list_reports").arrayValue ?? []
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?["kind"], .string("complete"))
        XCTAssertEqual(first.first?["body"], .string("done"))
        XCTAssertEqual(first.first?["task_id"], .string(task.id))

        let second = try await f.callJSON("list_reports").arrayValue ?? []
        XCTAssertEqual(second, [])
        XCTAssertEqual(try f.reports.unconsumedCount(projectId: f.project.id), 0)

        let id = try XCTUnwrap(first.first?["id"]?.numberValue)
        let again = try await f.callJSON("get_report", ["id": .number(id)])
        XCTAssertEqual(again["body"], .string("done"))
    }

    func testGetTaskIncludesLatestReportBody() async throws {
        let task = try f.task("t", column: .running)
        try f.session("w1", taskId: task.id)
        try f.board.complete(taskId: task.id, sessionId: "w1", summary: "summary text")

        let detail = try await f.callJSON("get_task", ["id": .string(task.id)])
        XCTAssertEqual(detail["latest_report"]?["body"], .string("summary text"))
        XCTAssertEqual(detail["column"], .string("review"))
    }

    // MARK: Approvals and proposals

    func testPromoteProposalRequiresAutonomy() async throws {
        let proposed = try f.board.propose(projectId: f.project.id, title: "idea", body: nil, rationale: nil, sessionId: nil)
        await XCTAssertToolError(try await f.call("promote_proposal", ["task_id": .string(proposed.id)]), containing: "autonomy is off")
        XCTAssertEqual(try f.tasks.get(proposed.id)?.column, .proposed)

        try f.setAutonomy(true)
        _ = try await f.call("promote_proposal", ["task_id": .string(proposed.id)])
        XCTAssertEqual(try f.tasks.get(proposed.id)?.column, .ready)
    }

    func testListApprovalsShowsPendingSpawn() async throws {
        let task = try f.task("t", column: .ready)
        _ = try await f.call("spawn_worker", ["task_id": .string(task.id)])
        let list = try await f.callJSON("list_approvals").arrayValue ?? []
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?["kind"], .string("spawn"))
        XCTAssertEqual(list.first?["task_id"], .string(task.id))
    }

    func testRequestIntegrationCreatesApprovalForEpicInProject() async throws {
        let epic = Epic(id: Epic.newId(), projectId: f.project.id, title: "E", goal: nil, branch: "epic/e", state: .active, createdAt: .nowMillis)
        try await f.db.writer.write { db in try epic.insert(db) }

        let result = try await f.call("request_integration", ["epic_id": .string(epic.id)])
        XCTAssertTrue(result.text.hasPrefix("integration approval "), result.text)
        XCTAssertTrue(result.text.hasSuffix(" pending"))

        let pending = try f.approvals.pending(projectId: f.project.id)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.kind, .integration)
        XCTAssertEqual(pending.first?.epicId, epic.id)

        await XCTAssertToolError(try await f.call("request_integration", ["epic_id": .string("nope")]), containing: "not in this project")
    }

    // MARK: Notes

    func testOrchestratorHasEveryWorkerNoteToolPlusAttachAndPin() async {
        let names = await f.orchestrator.tools(for: f.orchestratorIdentity).map(\.name)
        for tool in ["search_notes", "read_note", "append_section", "replace_section", "create_note", "attach_note", "pin_note"] {
            XCTAssertTrue(names.contains(tool), "orchestrator scope is missing \(tool)")
        }
        XCTAssertEqual(Set(names).count, names.count, "duplicate tool name in the orchestrator list")
    }

    func testOrchestratorNoteWritesRoundTrip() async throws {
        let created = try await f.callJSON("create_note", [
            "title": .string("Integration order"),
            "sections": .array([.object(["heading": .string("Order"), "body": .string("Bridge before UI.")])]),
        ])
        let id = try XCTUnwrap(created["id"]?.stringValue)

        _ = try await f.call("append_section", [
            "note_id": .string(id), "heading": .string("Order"), "body": .string("Then docs."), "if_version": .number(1),
        ])
        _ = try await f.call("replace_section", [
            "note_id": .string(id), "heading": .string("Risk"), "body": .string("FTS index is hand-maintained."), "if_version": .number(2),
        ])

        let note = try await f.callJSON("read_note", ["id": .string(id)])
        XCTAssertEqual(note["version"], .number(3))
        let sections = try XCTUnwrap(note["sections"]?.arrayValue)
        XCTAssertEqual(sections.map { $0["heading"] }, [.string("Order"), .string("Risk")])
        XCTAssertEqual(sections.first?["body"], .string("Bridge before UI.\n\nThen docs."))

        let found = try await f.callJSON("search_notes", ["query": .string("hand-maintained")]).arrayValue ?? []
        XCTAssertEqual(found.map { $0["id"] }, [.string(id)])
    }

    func testOrchestratorIfVersionConflictNamesTheCurrentVersionAndWritesNothing() async throws {
        let note = try f.note("Constraints", sections: [(heading: "DB", body: "One writer.")])
        try f.notes.appendSection(noteId: note.id, heading: "DB", body: "A worker got here first.")

        await XCTAssertToolError(
            try await f.call("replace_section", [
                "note_id": .string(note.id), "heading": .string("DB"), "body": .string("Stale."), "if_version": .number(1),
            ]),
            containing: "now at version 2"
        )
        XCTAssertEqual(try f.notes.get(note.id)?.version, 2)
        XCTAssertEqual(try f.notes.read(note.id)?.1.first?.body, "One writer.\n\nA worker got here first.")
    }

    func testPinNoteTogglesPinning() async throws {
        let note = try f.note("Always true")

        let pinned = try await f.call("pin_note", ["note_id": .string(note.id), "pinned": .bool(true)])
        XCTAssertTrue(pinned.text.contains("Always true"), pinned.text)
        XCTAssertEqual(try f.notes.pinned(projectId: f.project.id).map(\.id), [note.id])

        _ = try await f.call("pin_note", ["note_id": .string(note.id), "pinned": .bool(false)])
        XCTAssertEqual(try f.notes.pinned(projectId: f.project.id).count, 0)
    }

    func testPinNoteRequiresABoolean() async throws {
        let note = try f.note("Always true")
        await XCTAssertToolError(
            try await f.call("pin_note", ["note_id": .string(note.id), "pinned": .string("yes")]),
            containing: "true or false"
        )
    }

    func testAttachNoteToTaskAndEpic() async throws {
        let note = try f.note("Shared constraint")
        let task = try f.task("t")
        let epic = try f.epic("E")

        _ = try await f.call("attach_note", ["note_id": .string(note.id), "task_id": .string(task.id)])
        _ = try await f.call("attach_note", ["note_id": .string(note.id), "epic_id": .string(epic.id)])

        XCTAssertEqual(try f.notes.notes(forTask: task.id).map(\.id), [note.id])
        XCTAssertEqual(try f.notes.notes(forEpic: epic.id).map(\.id), [note.id])
    }

    func testAttachNoteIsIdempotent() async throws {
        let note = try f.note("Shared constraint")
        let task = try f.task("t")

        _ = try await f.call("attach_note", ["note_id": .string(note.id), "task_id": .string(task.id)])
        _ = try await f.call("attach_note", ["note_id": .string(note.id), "task_id": .string(task.id)])

        XCTAssertEqual(try f.notes.links(noteId: note.id).count, 1)
    }

    func testAttachNoteNeedsExactlyOneTarget() async throws {
        let note = try f.note("Shared constraint")
        let task = try f.task("t")
        let epic = try f.epic("E")

        await XCTAssertToolError(try await f.call("attach_note", ["note_id": .string(note.id)]), containing: "has to be attached")
        await XCTAssertToolError(
            try await f.call("attach_note", [
                "note_id": .string(note.id), "task_id": .string(task.id), "epic_id": .string(epic.id),
            ]),
            containing: "not both"
        )
        XCTAssertEqual(try f.notes.links(noteId: note.id).count, 0)
    }

    func testOrchestratorCannotReachAnotherProjectsNotesOrTargets() async throws {
        let other = try f.otherProject()
        let foreignNote = try f.note("Theirs", in: other.id)
        let foreignTask = try f.task("theirs", in: other.id)
        let ourNote = try f.note("Ours")

        await XCTAssertToolError(try await f.call("read_note", ["id": .string(foreignNote.id)]), containing: "not in this project")
        await XCTAssertToolError(
            try await f.call("pin_note", ["note_id": .string(foreignNote.id), "pinned": .bool(true)]),
            containing: "not in this project"
        )
        await XCTAssertToolError(
            try await f.call("attach_note", ["note_id": .string(foreignNote.id), "task_id": .string(foreignTask.id)]),
            containing: "not in this project"
        )
        await XCTAssertToolError(
            try await f.call("attach_note", ["note_id": .string(ourNote.id), "task_id": .string(foreignTask.id)]),
            containing: "not in this project"
        )
        await XCTAssertToolError(
            try await f.call("attach_note", ["note_id": .string(ourNote.id), "epic_id": .string("nope")]),
            containing: "not in this project"
        )

        XCTAssertEqual(try f.notes.get(foreignNote.id)?.pinned, false)
        XCTAssertEqual(try f.notes.links(noteId: ourNote.id).count, 0)

        let search = try await f.callJSON("search_notes", ["query": .string("Theirs")]).arrayValue ?? []
        XCTAssertEqual(search.count, 0)
    }
}
