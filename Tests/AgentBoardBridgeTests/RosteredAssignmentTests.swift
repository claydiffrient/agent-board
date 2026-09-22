import AgentBoardBridge
import AgentBoardCore
import AgentBoardServer
import Foundation
import XCTest

/// `assign_to_agent` and `list_roster_agents`: the orchestrator's route into the roster.
final class AssignToAgentTests: XCTestCase {
    private var f: BridgeFixture!

    override func setUpWithError() throws {
        f = try BridgeFixture.make()
        try f.setAutonomy(true)
    }

    @discardableResult
    private func rostered(_ name: String, role: String = "frontend") throws -> RosterAgent {
        try f.rosterReviewer(name, role: role)
    }

    func testAssignDispatchesTheNamedAgentWithWorkerScope() async throws {
        let ada = try rostered("Ada")
        let task = try f.task("ship search", column: .ready)

        let result = try await f.call(
            "assign_to_agent", ["task_id": .string(task.id), "roster_agent_id": .string(ada.id)]
        )

        let assigned = await f.control.assigned
        XCTAssertEqual(assigned.count, 1)
        XCTAssertEqual(assigned.first?.taskId, task.id)
        XCTAssertEqual(assigned.first?.rosterAgentId, ada.id)
        XCTAssertEqual(assigned.first?.scope, .worker, "assign_to_agent must never mint a reviewer grant")
        XCTAssertTrue(result.text.contains("Ada"))
    }

    func testAnAgentThisProjectHasNotEnabledIsRefusedAndNothingIsDispatched() async throws {
        let roster = RosterStore(f.db)
        let outsider = try roster.create(name: "Bee", role: "backend", systemPrompt: "p")
        let task = try f.task("ship search", column: .ready)

        await XCTAssertThrowsErrorAsync(
            try await f.call(
                "assign_to_agent",
                ["task_id": .string(task.id), "roster_agent_id": .string(outsider.id)]
            )
        )
        let assigned = await f.control.assigned
        XCTAssertTrue(assigned.isEmpty)
    }

    func testADisabledAgentAndAnUnknownIdAreBothRefused() async throws {
        let ada = try rostered("Ada")
        try RosterStore(f.db).setEnabled(ada.id, false)
        let task = try f.task("ship search", column: .ready)

        for id in [ada.id, "no-such-agent"] {
            await XCTAssertThrowsErrorAsync(
                try await f.call("assign_to_agent", ["task_id": .string(task.id), "roster_agent_id": .string(id)])
            )
        }
        let assigned = await f.control.assigned
        XCTAssertTrue(assigned.isEmpty)
    }

    func testAssignHonoursTheAutonomyApprovalGateJustLikeSpawnWorker() async throws {
        let ada = try rostered("Ada")
        try f.setAutonomy(false)
        let task = try f.task("ship search", column: .ready)

        let result = try await f.call(
            "assign_to_agent", ["task_id": .string(task.id), "roster_agent_id": .string(ada.id)]
        )

        XCTAssertTrue(result.text.contains("pending"), result.text)
        let assigned = await f.control.assigned
        XCTAssertTrue(assigned.isEmpty, "an approval must gate the dispatch, not follow it")
        XCTAssertEqual(try f.approvals.pending(projectId: f.project.id).count, 1)
    }

    func testListRosterAgentsShowsOnlyThisProjectsUsableAgentsInItsOwnOrder() async throws {
        let roster = RosterStore(f.db)
        let ada = try rostered("Ada")
        let bee = try rostered("Bee", role: "backend")
        let disabled = try rostered("Cy", role: "docs")
        try roster.setEnabled(disabled.id, false)
        _ = try roster.create(name: "Outsider", role: "ops", systemPrompt: "p")
        try roster.setOrder(forProject: f.project.id, agentIds: [bee.id, ada.id])

        let json = try await f.callJSON("list_roster_agents")
        let names = (json.arrayValue ?? []).compactMap { $0["name"]?.stringValue }

        XCTAssertEqual(names, ["Bee", "Ada"])
    }

    func testGetTaskNamesTheAgentOnTheTask() async throws {
        let ada = try rostered("Ada")
        let task = try f.task("ship search", column: .ready)
        try f.tasks.setRosterAgent(task.id, ada.id)

        let json = try await f.callJSON("get_task", ["id": .string(task.id)])

        XCTAssertEqual(json["roster_agent"]?["name"]?.stringValue, "Ada")
        XCTAssertEqual(json["roster_agent"]?["role"]?.stringValue, "frontend")
    }
}

/// The last step of agent review: completing under `.agent` starts the reviewer, rather than
/// parking the task and stopping.
final class AgentReviewSpawnTests: XCTestCase {
    private var f: BridgeFixture!
    private var task: BoardTask!
    private var worker: TokenIdentity!

    override func setUpWithError() throws {
        f = try BridgeFixture.make()
        try f.setReviewLevel(.agent)
        task = try f.task("ship search", column: .ready)
        try f.board.assign(
            taskId: task.id,
            session: AgentSession(
                sessionId: "s1", shortId: "alpha", projectId: f.project.id, taskId: task.id, role: .worker,
                worktreePath: "/wt/\(task.id)", branch: "agentboard/\(task.id)", cwd: "/wt/\(task.id)",
                state: .running
            )
        )
        worker = f.workerIdentity(sessionId: "s1", taskId: task.id)
    }

    @discardableResult
    private func reportComplete() async throws -> ToolResult {
        try await f.call(
            "report_complete",
            [
                "summary": .string("Wrote the query layer."),
                "files_changed": .array([.string("Sources/Search.swift")]),
                "tests_run": .string("swift test"),
                "caveats": .string("none"),
            ],
            as: worker
        )
    }

    func testCompletingUnderAgentReviewSpawnsTheReviewerWithReviewerScope() async throws {
        let rae = try f.rosterReviewer("Rae")

        let result = try await reportComplete()

        let assigned = await f.control.assigned
        XCTAssertEqual(assigned.count, 1)
        XCTAssertEqual(assigned.first?.taskId, task.id)
        XCTAssertEqual(assigned.first?.rosterAgentId, rae.id)
        XCTAssertEqual(assigned.first?.scope, .reviewer)
        XCTAssertEqual(try f.tasks.get(task.id)?.column, .review)
        XCTAssertEqual(try f.tasks.get(task.id)?.reviewerAgentId, rae.id)
        XCTAssertTrue(result.text.contains("Rae"), result.text)
    }

    /// The transport resends `report_complete` when the answer is lost, which is routine here. Under
    /// agent review a resend that got through the guard would put a second reviewer into the same
    /// worktree on the same branch, so the answer must come back before any of the routing runs.
    func testAResentReportCompleteStartsNoSecondReviewer() async throws {
        let rae = try f.rosterReviewer("Rae")

        let first = try await reportComplete()
        let rowsAfterFirst = try f.progress.list(taskId: task.id).map(\.text)
        try f.tasks.setReviewer(task.id, nil)

        let second = try await reportComplete()

        let assigned = await f.control.assigned
        XCTAssertEqual(assigned.count, 1, "the resend spawned a second reviewer")
        XCTAssertEqual(assigned.first?.rosterAgentId, rae.id)
        XCTAssertNil(try f.tasks.get(task.id)?.reviewerAgentId, "the resend assigned the reviewer again")
        XCTAssertEqual(
            try f.progress.list(taskId: task.id).map(\.text), rowsAfterFirst,
            "the resend appended the agent-review progress row a second time"
        )
        XCTAssertEqual(try f.reports.unconsumed(projectId: f.project.id).filter { $0.kind == .complete }.count, 1)
        XCTAssertTrue(first.text.contains("Rae"), first.text)
        XCTAssertTrue(second.text.contains("was already recorded"), second.text)

        let events = await f.events.events
        XCTAssertEqual(events.filter { $0 == .workerCompleted(projectId: f.project.id, sessionId: "s1") }.count, 1)
        XCTAssertEqual(events.filter { $0 == .reportQueued(projectId: f.project.id) }.count, 1)
    }

    func testAReviewerThatCannotBeStartedLeavesTheTaskInReviewForAPerson() async throws {
        try f.rosterReviewer("Rae")
        await f.control.setAssignFailure(BoardError.projectNotFound("gone"))

        let result = try await reportComplete()

        XCTAssertEqual(try f.tasks.get(task.id)?.column, .review)
        XCTAssertTrue(result.text.contains("a person will look at it"), result.text)
        let logged = try f.progress.list(taskId: task.id).map(\.text)
        XCTAssertTrue(logged.contains { $0.contains("could not be started") }, logged.description)
    }

    func testWithNoRosteredReviewerNothingIsSpawnedAndTheTaskWaitsOnAHuman() async throws {
        let result = try await reportComplete()

        let assigned = await f.control.assigned
        XCTAssertTrue(assigned.isEmpty)
        XCTAssertEqual(try f.tasks.get(task.id)?.column, .review)
        XCTAssertNil(try f.tasks.get(task.id)?.reviewerAgentId)
        XCTAssertTrue(result.text.contains("Review"), result.text)
    }

    /// Task review is the untouched path: no reviewer exists to start, so nothing may be dispatched.
    func testTaskReviewStillSpawnsNothing() async throws {
        try f.setReviewLevel(.task)
        try f.rosterReviewer("Rae")

        _ = try await reportComplete()

        let assigned = await f.control.assigned
        XCTAssertTrue(assigned.isEmpty)
    }
}
