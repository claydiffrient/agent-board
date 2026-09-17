import AgentBoardBridge
import AgentBoardCore
import AgentBoardServer
import Foundation
import XCTest

final class WorkerHandOffToolTests: XCTestCase {
    private var f: BridgeFixture!
    private var task: BoardTask!
    private var worker: TokenIdentity!

    override func setUpWithError() throws {
        f = try BridgeFixture.make()
        task = try f.task("ship search", column: .ready)
        try f.board.assign(
            taskId: task.id,
            session: AgentSession(
                sessionId: "s1", shortId: "alpha", projectId: f.project.id, taskId: task.id, role: .worker,
                worktreePath: "/wt/\(task.id)", branch: "agentboard/\(task.id)", cwd: "/wt/\(task.id)", state: .running
            )
        )
        worker = f.workerIdentity(sessionId: "s1", taskId: task.id)
    }

    @discardableResult
    private func handOff(
        summary: String = "Wrote the query layer; the UI is untouched.",
        nextRole: JSONValue = .string("reviewer"),
        files: [JSONValue] = [.string("Sources/Search.swift")],
        as identity: TokenIdentity? = nil
    ) async throws -> ToolResult {
        try await f.call(
            "hand_off",
            ["summary": .string(summary), "next_role": nextRole, "files_changed": .array(files)],
            as: identity ?? worker
        )
    }

    func testHandOffIsInTheWorkerScopeAndNotTheOrchestratorScope() async {
        let workerTools = await f.scoped.tools(for: worker).map(\.name)
        XCTAssertTrue(workerTools.contains("hand_off"))
        let orchestratorTools = await f.scoped.tools(for: f.orchestratorIdentity).map(\.name)
        XCTAssertFalse(orchestratorTools.contains("hand_off"))
    }

    func testTheDescriptionWarnsThatUncommittedWorkIsNotAttributable() async throws {
        let all = await f.worker.tools(for: worker)
        let descriptor = try XCTUnwrap(all.first { $0.name == "hand_off" })
        XCTAssertTrue(descriptor.description.contains("not attributable"), descriptor.description)
        XCTAssertTrue(descriptor.description.contains("Commit"), descriptor.description)
        let nextRole = descriptor.inputSchema["properties"]?["next_role"]?["description"]?.stringValue ?? ""
        XCTAssertTrue(nextRole.contains("Advisory only"), nextRole)
        XCTAssertEqual(descriptor.inputSchema["additionalProperties"], .bool(false))
    }

    func testHandOffReturnsTheTaskToReadyAndNeverFlagsFailure() async throws {
        try await handOff()

        let stored = try XCTUnwrap(f.tasks.get(task.id))
        XCTAssertEqual(stored.column, .ready)
        XCTAssertFalse(stored.failed)
        XCTAssertFalse(stored.blocked)
    }

    func testTheProgressRowRecordsTheAgentAndTheSuggestedNextRole() async throws {
        try await handOff()

        let entry = try XCTUnwrap(f.progress.latest(taskId: task.id))
        XCTAssertEqual(entry.sessionId, "s1")
        XCTAssertTrue(entry.text.contains("alpha"), entry.text)
        XCTAssertTrue(entry.text.contains("reviewer"), entry.text)
        XCTAssertTrue(entry.text.contains("Wrote the query layer"), entry.text)
    }

    func testTheOrchestratorPullsTheHandOffThroughListReports() async throws {
        try await handOff()

        let reports = try await f.callJSON("list_reports").arrayValue ?? []
        let handoff = try XCTUnwrap(reports.first { $0["kind"]?.stringValue == "handoff" })
        XCTAssertEqual(handoff["task_id"]?.stringValue, task.id)
        XCTAssertTrue(handoff["body"]?.stringValue?.contains("Suggested next role: reviewer") == true)
        XCTAssertTrue(handoff["body"]?.stringValue?.contains("Sources/Search.swift") == true)
        let queued = await f.events.events
        XCTAssertTrue(queued.contains(.reportQueued(projectId: f.project.id)))
    }

    /// The signal the supervisor stops the agent on. Without it the handed-off `claude` process
    /// stayed resident until the next periodic sweep, holding its context while the task it handed
    /// back sat in `ready` — dispatchable into that very worktree.
    func testHandOffRaisesWorkerCompletedSoNothingWaitsForTheSweep() async throws {
        try await handOff()

        let raised = await f.events.events
        XCTAssertTrue(
            raised.contains(.workerCompleted(projectId: f.project.id, sessionId: "s1")),
            "hand_off raised no workerCompleted, so only the sweep would stop the agent: \(raised)"
        )
    }

    /// `workerCompleted` says a session is over and nothing more. Emitting it from both paths must
    /// not blur them: the report kind, the task's column and the stop reason each still separate a
    /// hand-off from a completion, and every surface that tells them apart reads one of those.
    func testAHandOffAndACompletionRaiseTheSameSignalAndStayTellableApart() async throws {
        let finished = try f.task("ship the UI", column: .ready)
        try f.board.assign(
            taskId: finished.id,
            session: AgentSession(
                sessionId: "s2", shortId: "beta", projectId: f.project.id, taskId: finished.id, role: .worker,
                worktreePath: "/wt/\(finished.id)", branch: "agentboard/\(finished.id)",
                cwd: "/wt/\(finished.id)", state: .running
            )
        )

        try await handOff()
        _ = try await f.call(
            "report_complete",
            [
                "summary": .string("Shipped it."),
                "files_changed": .array([.string("Sources/UI.swift")]),
                "tests_run": .string("swift test"),
                "caveats": .string("none"),
            ],
            as: f.workerIdentity(sessionId: "s2", taskId: finished.id)
        )

        let raised = await f.events.events
        XCTAssertTrue(raised.contains(.workerCompleted(projectId: f.project.id, sessionId: "s1")))
        XCTAssertTrue(raised.contains(.workerCompleted(projectId: f.project.id, sessionId: "s2")))

        XCTAssertEqual(try f.reports.latest(taskId: task.id)?.kind, .handoff)
        XCTAssertEqual(try f.reports.latest(taskId: finished.id)?.kind, .complete)
        XCTAssertEqual(try f.tasks.get(task.id)?.column, .ready)
        XCTAssertEqual(try f.tasks.get(finished.id)?.column, .review)
        XCTAssertEqual(try f.sessions.get("s1")?.stopReason, "handed off to reviewer")
        XCTAssertNotEqual(try f.sessions.get("s2")?.stopReason, "handed off to reviewer")
        XCTAssertEqual(try f.sessions.get("s1")?.state, try f.sessions.get("s2")?.state)
    }

    func testTheWorktreeRowSurvivesAndTheSessionNoLongerHoldsTheTask() async throws {
        try await handOff()

        let session = try XCTUnwrap(f.sessions.get("s1"))
        XCTAssertEqual(session.worktreePath, "/wt/\(task.id)")
        XCTAssertEqual(session.branch, "agentboard/\(task.id)")
        XCTAssertFalse(session.state.isActive)
        XCTAssertNotEqual(session.state, .failed)
        XCTAssertNil(try f.sessions.activeHolder(worktreePath: "/wt/\(task.id)"))
    }

    func testTheNextAgentTakesTheSameWorktreeAndTheOldTokenCannotHandOffAgain() async throws {
        try await handOff()
        try f.board.assign(
            taskId: task.id,
            session: AgentSession(
                sessionId: "s2", projectId: f.project.id, taskId: task.id, role: .worker,
                worktreePath: "/wt/\(task.id)", cwd: "/wt/\(task.id)", state: .running
            )
        )

        await XCTAssertToolError(try await handOff(summary: "again"), containing: "not the agent currently working")
        XCTAssertEqual(try f.tasks.get(task.id)?.column, .running)
        XCTAssertEqual(try f.sessions.activeHolder(taskId: task.id)?.sessionId, "s2")
    }

    func testAWorkerTokenBoundToNoTaskIsRefused() async {
        let unbound = TokenIdentity(token: "w", scope: .worker, projectId: f.project.id, sessionId: "s1", taskId: nil)
        await XCTAssertToolError(try await handOff(as: unbound), containing: "not bound to a task")
    }

    func testAWorkerTokenBoundToAnotherProjectsTaskIsRefused() async throws {
        let other = try f.otherProject()
        let foreign = try f.task("theirs", column: .running, in: other.id)
        let identity = TokenIdentity(
            token: "w", scope: .worker, projectId: f.project.id, sessionId: "s1", taskId: foreign.id
        )

        await XCTAssertToolError(try await handOff(as: identity), containing: "not owned by this session")
        XCTAssertEqual(try f.tasks.get(foreign.id)?.column, .running)
    }

    func testAWorkerTokenBoundToASiblingTaskCannotHandThatSiblingOff() async throws {
        let sibling = try f.task("sibling", column: .ready)
        try f.board.assign(
            taskId: sibling.id,
            session: AgentSession(
                sessionId: "s2", projectId: f.project.id, taskId: sibling.id, role: .worker,
                worktreePath: "/wt/\(sibling.id)", cwd: "/wt/\(sibling.id)", state: .running
            )
        )
        // Session s1's token, forged to name the sibling's task id.
        let forged = f.workerIdentity(sessionId: "s1", taskId: sibling.id)

        await XCTAssertToolError(try await handOff(as: forged), containing: "not the agent currently working")
        XCTAssertEqual(try f.tasks.get(sibling.id)?.column, .running)
        XCTAssertEqual(try f.sessions.activeHolder(taskId: sibling.id)?.sessionId, "s2")
    }

    func testSummaryIsRequired() async {
        await XCTAssertToolError(
            try await f.call("hand_off", ["next_role": .string("reviewer"), "files_changed": .array([])], as: worker)
        )
        XCTAssertEqual(try? f.tasks.get(task.id)?.column, .running)
    }
}
