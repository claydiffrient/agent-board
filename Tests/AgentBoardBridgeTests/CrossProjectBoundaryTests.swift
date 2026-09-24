import AgentBoardBridge
import AgentBoardCore
import AgentBoardServer
import Foundation
import XCTest

/// Every tool on the orchestrator surface, classified by how it holds the project boundary, with a
/// refusal test per tool. `send_message` and `list_projects` are the only crossings; the sets below
/// fail the moment a new tool appears unclassified, or a classified one changes side.
final class CrossProjectBoundaryTests: XCTestCase {
    private var f: BridgeFixture!
    private var other: Project!

    /// Tools that never take an id from another project: they read or write only what
    /// `identity.projectId` owns, so there is no foreign id to refuse.
    static let scopedByIdentity: Set<String> = [
        "list_tasks", "create_task", "list_agents", "list_reports", "list_approvals",
        "create_epic", "list_epics", "push_branch", "search_notes", "create_note",
        "list_roster_agents",
    ]

    /// Tools that accept an id and must throw a `ToolError` when it belongs to another project.
    static let refusesForeignId: Set<String> = [
        "get_task", "update_task", "move_task", "set_epic", "set_deps", "log_progress",
        "spawn_worker", "stop_worker", "archive_task", "unarchive_task", "get_report",
        "promote_proposal", "get_epic", "request_integration", "close_epic", "open_pull_request",
        "read_note", "append_section", "replace_section", "attach_note", "pin_note",
        "assign_to_agent", "add_comment",
    ]

    /// The whole of the permitted crossing: queue text into another project's channel, and learn
    /// that other projects exist by id and name. Adding to this set is the widening this file exists
    /// to catch.
    static let crossesDeliberately: Set<String> = ["list_projects", "send_message"]

    override func setUpWithError() throws {
        f = try BridgeFixture.make()
        try f.session(try XCTUnwrap(f.orchestratorIdentity.sessionId), role: .orchestrator)
        other = try f.otherProject()
    }

    override func tearDown() {
        f = nil
        other = nil
    }

    private func orchestratorIdentity(for project: Project) -> TokenIdentity {
        TokenIdentity(
            token: "orch-\(project.id)", scope: .orchestrator,
            projectId: project.id, sessionId: "orch-\(project.id)-session"
        )
    }

    // MARK: The surface is fully classified

    func testEveryOrchestratorToolIsClassifiedByThisAudit() async {
        let surface = Set(await f.orchestrator.tools(for: f.orchestratorIdentity).map(\.name))
        let classified = Self.scopedByIdentity
            .union(Self.refusesForeignId)
            .union(Self.crossesDeliberately)

        XCTAssertEqual(
            surface.subtracting(classified), [],
            "a tool was added to the orchestrator surface without a cross-project test in this file"
        )
        XCTAssertEqual(classified.subtracting(surface), [], "this audit names tools that no longer exist")
        XCTAssertEqual(surface.count, 36)
    }

    func testOnlySendMessageAcceptsAnotherProjectsId() async {
        let takesAProjectId = await f.orchestrator.tools(for: f.orchestratorIdentity)
            .filter { $0.inputSchema["properties"]?.objectValue?.keys.contains("project_id") ?? false }
            .map(\.name)

        XCTAssertEqual(takesAProjectId, ["send_message"], "a second tool now names a project; it must be audited here")
    }

    func testTheOnlyCrossingsAreTheMessageTools() {
        XCTAssertEqual(Self.crossesDeliberately, ["list_projects", "send_message"])
    }

    // MARK: Tasks

    func testEveryTaskToolRefusesAnotherProjectsTask() async throws {
        let foreign = try f.task("foreign", column: .proposed, in: other.id)
        let mine = try f.task("mine")
        try f.setAutonomy(true)

        await XCTAssertToolError(try await f.call("get_task", ["id": .string(foreign.id)]), containing: "not in this project")
        await XCTAssertToolError(
            try await f.call("update_task", ["id": .string(foreign.id), "title": .string("seized")]),
            containing: "not in this project"
        )
        await XCTAssertToolError(
            try await f.call("move_task", ["id": .string(foreign.id), "column": .string("review")]),
            containing: "not in this project"
        )
        await XCTAssertToolError(
            try await f.call("log_progress", ["task_id": .string(foreign.id), "text": .string("x")]),
            containing: "not in this project"
        )
        await XCTAssertToolError(
            try await f.call("add_comment", ["task_id": .string(foreign.id), "body": .string("x")]),
            containing: "not in this project"
        )
        await XCTAssertToolError(
            try await f.call("archive_task", ["task_id": .string(foreign.id)]),
            containing: "not in this project"
        )
        await XCTAssertToolError(
            try await f.call("unarchive_task", ["task_id": .string(foreign.id)]),
            containing: "not in this project"
        )
        await XCTAssertToolError(
            try await f.call("promote_proposal", ["task_id": .string(foreign.id)]),
            containing: "not in this project"
        )
        await XCTAssertToolError(
            try await f.call("set_deps", ["task_id": .string(mine.id), "depends_on": .array([.string(foreign.id)])]),
            containing: "not in this project"
        )
        await XCTAssertToolError(
            try await f.call("set_deps", ["task_id": .string(foreign.id), "depends_on": .array([])]),
            containing: "not in this project"
        )
        await XCTAssertToolError(
            try await f.call("create_task", [
                "title": .string("borrowed dep"), "depends_on": .array([.string(foreign.id)]),
            ]),
            containing: "not in this project"
        )

        let untouched = try XCTUnwrap(f.tasks.get(foreign.id, includeArchived: true))
        XCTAssertEqual(untouched.title, "foreign")
        XCTAssertEqual(untouched.column, .proposed)
        XCTAssertFalse(untouched.isArchived)
        XCTAssertEqual(try f.tasks.deps(of: mine.id), [])
        XCTAssertEqual(try f.progress.list(taskId: foreign.id).count, 0)
        XCTAssertEqual(try CommentStore(f.db).list(taskId: foreign.id), [])
        XCTAssertEqual(try f.tasks.list(projectId: f.project.id).map(\.title).sorted(), ["mine"])
    }

    func testListTasksNeitherShowsNorSilentlyEmptiesAnotherProjectsBoard() async throws {
        try f.task("foreign", in: other.id)
        let foreignEpic = try f.epic("theirs", in: other.id)
        try f.task("foreign in epic", epicId: foreignEpic.id, in: other.id)
        let mine = try f.task("mine")

        let listed = try await f.callJSON("list_tasks").arrayValue ?? []
        XCTAssertEqual(listed.compactMap { $0["id"]?.stringValue }, [mine.id])

        // Filtering by a foreign epic must refuse, not answer "no tasks": an empty list reads as
        // "that epic has nothing in it" when the truth is "that epic is not yours".
        await XCTAssertToolError(
            try await f.call("list_tasks", ["epic_id": .string(foreignEpic.id)]),
            containing: "not in this project"
        )
    }

    // MARK: Epics

    func testEveryEpicToolRefusesAnotherProjectsEpic() async throws {
        let foreign = try f.epic("theirs", in: other.id)
        let mine = try f.task("mine")

        await XCTAssertToolError(try await f.call("get_epic", ["id": .string(foreign.id)]), containing: "not in this project")
        await XCTAssertToolError(
            try await f.call("request_integration", ["epic_id": .string(foreign.id)]),
            containing: "not in this project"
        )
        await XCTAssertToolError(
            try await f.call("close_epic", ["epic_id": .string(foreign.id), "state": .string("done")]),
            containing: "not in this project"
        )
        await XCTAssertToolError(
            try await f.call("set_epic", ["task_id": .string(mine.id), "epic_id": .string(foreign.id)]),
            containing: "not in this project"
        )
        await XCTAssertToolError(
            try await f.call("create_task", ["title": .string("smuggled"), "epic_id": .string(foreign.id)]),
            containing: "not in this project"
        )
        await XCTAssertToolError(
            try await f.call("open_pull_request", ["epic_id": .string(foreign.id), "title": .string("theirs")]),
            containing: "not in this project"
        )

        XCTAssertEqual(try EpicStore(f.db).get(foreign.id)?.state, .active)
        XCTAssertEqual(try f.tasks.get(mine.id)?.epicId, nil)
        XCTAssertEqual(try f.tasks.list(projectId: other.id).count, 0)
        XCTAssertEqual(try f.approvals.pending(projectId: other.id).count, 0)
    }

    func testListEpicsOnlyShowsThisProject() async throws {
        try f.epic("theirs", in: other.id)
        let mine = try f.epic("ours")
        let listed = try await f.callJSON("list_epics").arrayValue ?? []
        XCTAssertEqual(listed.compactMap { $0["id"]?.stringValue }, [mine.id])
    }

    // MARK: Sessions and spawning

    func testSpawningIntoAnotherProjectIsRefused() async throws {
        let foreign = try f.task("foreign", column: .ready, in: other.id)

        await XCTAssertToolError(
            try await f.call("spawn_worker", ["task_id": .string(foreign.id)]),
            containing: "not in this project"
        )

        let spawned = await f.control.spawned
        XCTAssertEqual(spawned, [], "no worker may be dispatched for another project's task")
        XCTAssertEqual(try f.sessions.forTask(foreign.id).count, 0)
        XCTAssertEqual(try f.approvals.pending(projectId: other.id).count, 0)
        XCTAssertEqual(try f.approvals.pending(projectId: f.project.id).count, 0)
    }

    /// The roster is the one cross-project table, so `assign_to_agent` has two foreign ids to
    /// refuse, not one: the task, and an agent only the other project has enabled.
    func testAssignToAgentRefusesBothAForeignTaskAndAForeignProjectsAgent() async throws {
        try f.setAutonomy(true)
        let roster = RosterStore(f.db)
        let mine = try f.task("mine", column: .ready)
        let foreignTask = try f.task("foreign", column: .ready, in: other.id)
        let ours = try roster.create(name: "Ada", role: "frontend", systemPrompt: "p")
        try roster.enable(agentId: ours.id, forProject: f.project.id)
        let theirs = try roster.create(name: "Bee", role: "backend", systemPrompt: "p")
        try roster.enable(agentId: theirs.id, forProject: other.id)

        await XCTAssertToolError(
            try await f.call(
                "assign_to_agent",
                ["task_id": .string(foreignTask.id), "roster_agent_id": .string(ours.id)]
            ),
            containing: "not in this project"
        )
        await XCTAssertToolError(
            try await f.call(
                "assign_to_agent",
                ["task_id": .string(mine.id), "roster_agent_id": .string(theirs.id)]
            ),
            containing: "usable set"
        )

        let assigned = await f.control.assigned
        XCTAssertEqual(assigned.count, 0)
        XCTAssertEqual(try f.sessions.forTask(foreignTask.id).count, 0)
        XCTAssertEqual(try f.approvals.pending(projectId: other.id).count, 0)
    }

    /// The roster spans projects, but the listing does not: a project sees only what it enabled.
    func testListRosterAgentsNeverShowsAnotherProjectsAgents() async throws {
        let roster = RosterStore(f.db)
        let theirs = try roster.create(name: "Bee", role: "backend", systemPrompt: "p")
        try roster.enable(agentId: theirs.id, forProject: other.id)

        let json = try await f.callJSON("list_roster_agents")

        XCTAssertEqual(json.arrayValue?.count, 0)
    }

    func testStoppingAnotherProjectsWorkerIsRefused() async throws {
        let foreign = try f.task("foreign", column: .running, in: other.id)
        try f.sessions.insert(AgentSession(
            sessionId: "w-theirs", projectId: other.id, taskId: foreign.id,
            role: .worker, cwd: "/tmp/theirs", state: .running
        ))

        await XCTAssertToolError(
            try await f.call("stop_worker", ["session_id": .string("w-theirs")]),
            containing: "not in this project"
        )

        let stopped = await f.control.stopped
        XCTAssertEqual(stopped, [])
        XCTAssertEqual(try f.sessions.get("w-theirs")?.state, .running)
    }

    func testListAgentsOnlyShowsThisProjectsSessions() async throws {
        try f.sessions.insert(AgentSession(
            sessionId: "w-theirs", projectId: other.id, taskId: nil,
            role: .worker, cwd: "/tmp/theirs", state: .running
        ))
        let mine = try f.task("mine", column: .running)
        try f.session("w-mine", taskId: mine.id)

        let roster = (try await f.callJSON("list_agents").arrayValue ?? [])
            .compactMap { $0["session_id"]?.stringValue }
        XCTAssertFalse(roster.contains("w-theirs"))
        XCTAssertEqual(Set(roster), ["w-mine", "orch-session"])
    }

    // MARK: Reports and approvals

    func testAnotherProjectsReportIsRefusedRatherThanReturned() async throws {
        let theirs = try f.reports.insert(
            projectId: other.id, taskId: nil, sessionId: nil, kind: .complete, body: "their private summary"
        )
        let id = try XCTUnwrap(theirs.id)

        await XCTAssertToolError(try await f.call("get_report", ["id": .number(Double(id))]), containing: "not in this project")
        await XCTAssertToolError(try await f.call("get_report", ["id": .string(String(id))]), containing: "not in this project")

        let mine = try await f.call("list_reports").text
        XCTAssertFalse(mine.contains("their private summary"))
        XCTAssertEqual(try f.reports.unconsumedCount(projectId: other.id), 1, "their queue must not be drained by our pull")
    }

    func testAnotherProjectsPendingApprovalsAreInvisible() async throws {
        let foreign = try f.task("foreign", column: .ready, in: other.id)
        _ = try f.approvals.create(
            projectId: other.id, kind: .spawn, taskId: foreign.id, epicId: nil,
            requestedBy: "orch-theirs", reason: "their private reason"
        )

        let listed = try await f.call("list_approvals").text
        let decoded = try await f.callJSON("list_approvals").arrayValue
        XCTAssertEqual(decoded?.count, 0)
        XCTAssertFalse(listed.contains("their private reason"))
        XCTAssertFalse(listed.contains(foreign.id))
        XCTAssertEqual(try f.approvals.pending(projectId: other.id).count, 1)
    }

    // MARK: Notes

    func testEveryNoteToolRefusesAnotherProjectsNote() async throws {
        let foreignNote = try f.note("Theirs", sections: [(heading: "H", body: "their private text")], in: other.id)
        let foreignTask = try f.task("foreign", in: other.id)
        let foreignEpic = try f.epic("theirs", in: other.id)
        let ourNote = try f.note("Ours")

        await XCTAssertToolError(try await f.call("read_note", ["id": .string(foreignNote.id)]), containing: "not in this project")
        await XCTAssertToolError(
            try await f.call("append_section", [
                "note_id": .string(foreignNote.id), "heading": .string("H"), "body": .string("ours"),
            ]),
            containing: "not in this project"
        )
        await XCTAssertToolError(
            try await f.call("replace_section", [
                "note_id": .string(foreignNote.id), "heading": .string("H"), "body": .string("ours"),
            ]),
            containing: "not in this project"
        )
        await XCTAssertToolError(
            try await f.call("pin_note", ["note_id": .string(foreignNote.id), "pinned": .bool(true)]),
            containing: "not in this project"
        )
        await XCTAssertToolError(
            try await f.call("attach_note", ["note_id": .string(ourNote.id), "task_id": .string(foreignTask.id)]),
            containing: "not in this project"
        )
        await XCTAssertToolError(
            try await f.call("attach_note", ["note_id": .string(ourNote.id), "epic_id": .string(foreignEpic.id)]),
            containing: "not in this project"
        )

        let (_, sections) = try XCTUnwrap(f.notes.read(foreignNote.id))
        XCTAssertEqual(sections.map(\.body), ["their private text"])
        XCTAssertEqual(try f.notes.get(foreignNote.id)?.pinned, false)
        XCTAssertEqual(try f.notes.links(noteId: ourNote.id).count, 0)

        let found = try await f.call("search_notes", ["query": .string("private")]).text
        XCTAssertFalse(found.contains(foreignNote.id))
    }

    func testANoteCreatedHereLandsInThisProjectOnly() async throws {
        _ = try await f.call("create_note", ["title": .string("Ours")])
        XCTAssertEqual(try f.notes.search(projectId: other.id, query: "Ours").count, 0)
        XCTAssertEqual(try f.notes.search(projectId: f.project.id, query: "Ours").count, 1)
    }

    // MARK: Publishing

    func testPushingCannotBeAimedAtAnotherProjectsWork() async throws {
        let foreign = try f.task("foreign", in: other.id)

        _ = try await f.call("push_branch", ["branch": .string(TaskStore.branchName(for: foreign.id))])

        XCTAssertEqual(try f.approvals.pending(projectId: other.id).count, 0, "the approval must not land on their board")
        let ours = try f.approvals.pending(projectId: f.project.id)
        XCTAssertEqual(ours.count, 1)
        XCTAssertNil(ours.first?.taskId, "a branch named for another project's task must not link to it")
        XCTAssertNil(ours.first?.epicId)
    }

    // MARK: The permitted crossing, and its edges

    func testTheOnlyThingListProjectsRevealsIsIdAndName() async throws {
        try f.task("their secret task", in: other.id)
        try f.epic("their secret epic", in: other.id)
        try f.note("their secret note", in: other.id)

        let listed = try await f.callJSON("list_projects").arrayValue ?? []
        for entry in listed {
            XCTAssertEqual(Set(entry.objectValue?.keys ?? [:].keys), ["id", "name", "is_self"], "\(entry)")
        }

        let rendered = try await f.call("list_projects").text
        for leak in ["secret", other.repoPath, other.worktreeRoot, other.baseBranch] {
            XCTAssertFalse(rendered.contains(leak), "list_projects leaked \(leak)")
        }
    }

    func testAQueuedMessageCarriesTheSenderIdentityAndNothingElseAboutTheSendersBoard() async throws {
        let task = try f.task("our secret task")
        let epic = try f.epic("our secret epic")
        let sessionId = try XCTUnwrap(f.orchestratorIdentity.sessionId)

        _ = try await f.call("send_message", [
            "project_id": .string(other.id), "body": .string("The shared schema moved."),
        ])

        let delivered = try XCTUnwrap(f.reports.unconsumed(projectId: other.id).first)
        XCTAssertEqual(delivered.kind, .message)
        XCTAssertNil(delivered.taskId, "a message must not hang off a task the recipient cannot resolve")
        XCTAssertNil(delivered.sessionId, "the sending session belongs to the other board")

        XCTAssertTrue(delivered.body.contains(f.project.id), "the recipient must know who is speaking")
        XCTAssertTrue(delivered.body.contains(f.project.name))
        XCTAssertEqual(CrossProjectMessage.text(inDeliveredBody: delivered.body), "The shared schema moved.")

        for leak in [
            task.id, epic.id, epic.branch, sessionId, f.project.repoPath, f.project.worktreeRoot,
            TaskStore.branchName(for: task.id), "our secret",
        ] {
            XCTAssertFalse(delivered.body.contains(leak), "the delivered message leaked \(leak)")
        }
    }

    func testSendMessageQueuesTextAndChangesNothingElseOnTheRecipientsBoard() async throws {
        let theirTask = try f.task("theirs", column: .ready, in: other.id)

        _ = try await f.call("send_message", ["project_id": .string(other.id), "body": .string("hello")])

        XCTAssertEqual(try f.tasks.get(theirTask.id)?.column, .ready)
        XCTAssertEqual(try f.tasks.list(projectId: other.id).count, 1)
        XCTAssertEqual(try f.sessions.all(projectId: other.id).count, 0)
        XCTAssertEqual(try f.approvals.pending(projectId: other.id).count, 0)
        XCTAssertEqual(try f.notes.search(projectId: other.id, query: "hello").count, 0)
        XCTAssertEqual(try EpicStore(f.db).list(projectId: other.id).count, 0)
        XCTAssertEqual(try f.reports.unconsumed(projectId: other.id).count, 1)
    }

    func testReadingTheOtherProjectIsStillRefusedAfterAMessageIsSent() async throws {
        let theirTask = try f.task("theirs", in: other.id)
        _ = try await f.call("send_message", ["project_id": .string(other.id), "body": .string("hello")])

        await XCTAssertToolError(try await f.call("get_task", ["id": .string(theirTask.id)]), containing: "not in this project")
        let mine = try await f.callJSON("list_reports").arrayValue
        XCTAssertEqual(mine?.count, 0)
    }

    // MARK: The worker surface

    func testTheMessageToolsAreAbsentFromTheWorkerSurfaceNotMerelyRefused() async throws {
        let task = try f.task("mine")
        try f.session("w1", taskId: task.id)
        let worker = f.workerIdentity(sessionId: "w1", taskId: task.id)

        let workerTools = Set(await f.scoped.tools(for: worker).map(\.name))
        XCTAssertTrue(
            workerTools.isDisjoint(with: Self.crossesDeliberately),
            "the crossing tools must not be listed to a worker at all"
        )
        XCTAssertTrue(
            workerTools.isDisjoint(with: Self.scopedByIdentity.subtracting(["search_notes", "create_note"])),
            "the orchestrator-only board tools must not be listed to a worker"
        )

        // Absent, and refused if guessed by name: the worker handler has no case for either.
        await XCTAssertToolError(try await f.call("list_projects", as: worker), containing: "Unknown tool")
        await XCTAssertToolError(
            try await f.call("send_message", ["project_id": .string(other.id), "body": .string("hi")], as: worker),
            containing: "Unknown tool"
        )
        XCTAssertEqual(try MessageStore(f.db).inbox(projectId: other.id).count, 0)
    }

    func testAWorkerCannotReachAnotherProjectsBoardThroughItsOwnTools() async throws {
        let task = try f.task("mine")
        try f.session("w1", taskId: task.id)
        let worker = f.workerIdentity(sessionId: "w1", taskId: task.id)
        let foreignNote = try f.note("Theirs", sections: [(heading: "H", body: "their private text")], in: other.id)

        await XCTAssertToolError(
            try await f.call("read_note", ["id": .string(foreignNote.id)], as: worker),
            containing: "not in this project"
        )
        await XCTAssertToolError(
            try await f.call("append_section", [
                "note_id": .string(foreignNote.id), "heading": .string("H"), "body": .string("ours"),
            ], as: worker),
            containing: "not in this project"
        )
        let found = try await f.call("search_notes", ["query": .string("private")], as: worker).text
        XCTAssertFalse(found.contains(foreignNote.id))

        _ = try await f.call("propose_task", ["title": .string("follow-up")], as: worker)
        XCTAssertEqual(try f.tasks.list(projectId: other.id, column: .proposed).count, 0)
    }

    // MARK: An unknown id reads the same as a foreign one, deliberately

    func testAnUnknownIdIsRefusedTheSameWayAsAForeignOneSoIdsCannotBeProbed() async throws {
        let foreign = try f.task("foreign", in: other.id)

        await XCTAssertToolError(try await f.call("get_task", ["id": .string("no-such-task")]), containing: "not in this project")
        await XCTAssertToolError(try await f.call("get_task", ["id": .string(foreign.id)]), containing: "not in this project")
        await XCTAssertToolError(try await f.call("get_epic", ["id": .string("no-such-epic")]), containing: "not in this project")
        await XCTAssertToolError(try await f.call("read_note", ["id": .string("no-such-note")]), containing: "not in this project")
    }
}
