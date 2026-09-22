import AgentBoardCore
import AgentBoardRuntime
import Foundation
import XCTest
@testable import AgentBoard

/// What a rostered agent actually gets when it is spawned, against a real git repository.
@MainActor
final class RosteredSpawnTests: XCTestCase {
    private var fixture: SupervisorFixture!

    override func setUp() async throws {
        fixture = try SupervisorFixture.make(gitRepo: true)
        await fixture.supervisor.start()
        try XCTSkipIf(fixture.supervisor.serverPort == nil, "the board server could not bind a port")
    }

    override func tearDown() async throws {
        await fixture.supervisor.waitForSetup()
        fixture.cleanUp()
        fixture = nil
    }

    private var roster: RosterStore { RosterStore(fixture.db) }

    @discardableResult
    private func rostered(
        _ name: String, role: String = "frontend", model: String? = nil, disallowedTools: [String] = []
    ) throws -> RosterAgent {
        let agent = try roster.create(
            name: name, role: role, systemPrompt: "You own the front end.", model: model,
            disallowedTools: disallowedTools
        )
        try roster.enable(agentId: agent.id, forProject: fixture.project.id)
        return agent
    }

    private func makeTask(_ title: String = "Do the thing", model: String? = nil) throws -> BoardTask {
        let task = try fixture.tasks.create(
            projectId: fixture.project.id, title: title, body: "Do it.", acceptance: "It works.",
            priority: nil, column: .ready, origin: .human, epicId: nil
        )
        guard let model else { return task }
        var withModel = task
        withModel.model = model
        try fixture.tasks.update(withModel)
        return try XCTUnwrap(fixture.tasks.get(task.id))
    }

    private func assign(_ task: BoardTask, as agent: RosterAgent) async throws {
        _ = try await fixture.supervisor.assignAgent(
            taskId: task.id, rosterAgentId: agent.id, scope: .worker
        )
        await fixture.supervisor.waitForSetup()
    }

    private func lastRequest() async throws -> SpawnRequest {
        let spawns = await fixture.runtime.spawns
        return try XCTUnwrap(spawns.last)
    }

    // MARK: disallowed_tools is a deny-list and can only narrow

    func testAnAgentsDisallowedToolsAreLayeredOntoTheWorkerDefault() async throws {
        let ada = try rostered("Ada", disallowedTools: ["Bash(rm *)", "WebFetch"])

        try await assign(try makeTask(), as: ada)

        let request = try await lastRequest()
        XCTAssertEqual(request.disallowedTools, SpawnRequest.defaultDisallowedTools + ["Bash(rm *)", "WebFetch"])
        // The whole point: the default list survives intact, so a rostered agent cannot hand itself
        // back a tool a plain worker is refused.
        for defaulted in SpawnRequest.defaultDisallowedTools {
            XCTAssertTrue(request.disallowedTools.contains(defaulted), defaulted)
        }
    }

    func testAnEmptyDisallowedListIsExactlyAPlainWorkersAuthority() async throws {
        let ada = try rostered("Ada")

        try await assign(try makeTask(), as: ada)

        let request = try await lastRequest()
        XCTAssertEqual(request.disallowedTools, SpawnRequest.defaultDisallowedTools)
    }

    func testARosteredAgentGetsTheSameDenyListAsAnUnrosteredWorkerPlusItsOwn() async throws {
        try await fixture.supervisor.assign(taskId: try makeTask("plain").id)
        await fixture.supervisor.waitForSetup()
        let plain = try await lastRequest()

        let ada = try rostered("Ada", disallowedTools: ["WebFetch"])
        try await assign(try makeTask("rostered"), as: ada)

        let rosteredRequest = try await lastRequest()
        XCTAssertEqual(rosteredRequest.disallowedTools, plain.disallowedTools + ["WebFetch"])
    }

    // MARK: identity, model and the recorded assignment

    func testTheIdentitySectionLeadsTheSpawnedPrompt() async throws {
        let ada = try rostered("Ada")

        try await assign(try makeTask(), as: ada)

        let prompt = try await lastRequest().prompt
        XCTAssertTrue(prompt.hasPrefix("# You are Ada"), String(prompt.prefix(80)))
        XCTAssertTrue(prompt.contains("Your specialty is frontend"))
        XCTAssertTrue(prompt.contains("You own the front end."))
    }

    func testModelPrecedenceIsTaskThenAgentThenProjectDefault() async throws {
        let ada = try rostered("Ada", model: "claude-opus-5")

        try await assign(try makeTask("agent wins", model: nil), as: ada)
        let agentWins = try await lastRequest()
        XCTAssertEqual(agentWins.model, "claude-opus-5")

        try await assign(try makeTask("task wins", model: "claude-haiku-4-5-20251001"), as: ada)
        let taskWins = try await lastRequest()
        XCTAssertEqual(taskWins.model, "claude-haiku-4-5-20251001")
    }

    func testTheAssignmentIsRecordedOnBothTheSessionAndTheTask() async throws {
        let ada = try rostered("Ada")
        let task = try makeTask()

        try await assign(task, as: ada)

        let session = try XCTUnwrap(fixture.sessions.forTask(task.id).last)
        XCTAssertEqual(session.rosterAgentId, ada.id)
        XCTAssertTrue(session.isRostered)
        XCTAssertEqual(try fixture.tasks.get(task.id)?.rosterAgentId, ada.id)
        XCTAssertEqual(try fixture.tasks.get(task.id)?.column, .running)
    }

    func testAnAgentTheProjectHasNotEnabledIsRefusedBeforeAnythingIsSpawned() async throws {
        let outsider = try roster.create(name: "Bee", role: "backend", systemPrompt: "p")
        let task = try makeTask()

        do {
            _ = try await fixture.supervisor.assignAgent(
                taskId: task.id, rosterAgentId: outsider.id, scope: .worker
            )
            XCTFail("an agent outside the project's usable set was dispatched")
        } catch SupervisorError.rosterAgentNotUsable(let id, let projectName) {
            XCTAssertEqual(id, outsider.id)
            XCTAssertEqual(projectName, fixture.project.name)
        }
        let spawns = await fixture.runtime.spawns
        XCTAssertTrue(spawns.isEmpty)
        XCTAssertEqual(try fixture.tasks.get(task.id)?.column, .ready)
    }

    // MARK: the reviewer

    /// The spawn is keyed on the task id, so a reviewer lands in the worker's own worktree on the
    /// worker's branch — which is exactly what a reviewer needs and costs nothing to arrange.
    func testAReviewerRunsInTheWorkersWorktreeAndHoldsAReviewerGrant() async throws {
        let rae = try rostered("Rae", role: "reviewer")
        let task = try makeTask()
        try await fixture.supervisor.assign(taskId: task.id)
        await fixture.supervisor.waitForSetup()
        let worker = try XCTUnwrap(fixture.sessions.forTask(task.id).last)
        _ = try fixture.board.complete(
            taskId: task.id, sessionId: worker.sessionId, summary: "done"
        )

        let spawn = try await fixture.supervisor.assignAgent(
            taskId: task.id, rosterAgentId: rae.id, scope: .reviewer
        )
        await fixture.supervisor.waitForSetup()

        XCTAssertEqual(spawn.worktreePath, worker.cwd)
        XCTAssertEqual(spawn.branch, worker.branch)
        XCTAssertEqual(try fixture.tasks.get(task.id)?.column, .review, "the review must stay in the queue")

        let reviewer = try XCTUnwrap(
            fixture.sessions.forTask(task.id).last { $0.sessionId != worker.sessionId }
        )
        XCTAssertEqual(reviewer.rosterAgentId, rae.id)
        let scopes = try fixture.grants.forSession(reviewer.sessionId).map(\.scope)
        XCTAssertEqual(scopes, [.reviewer], "the reviewer session must hold a reviewer grant and nothing wider")
    }

    func testAWorkerScopedRosteredSpawnStillMintsAWorkerGrant() async throws {
        let ada = try rostered("Ada")
        let task = try makeTask()

        try await assign(task, as: ada)

        let session = try XCTUnwrap(fixture.sessions.forTask(task.id).last)
        XCTAssertEqual(try fixture.grants.forSession(session.sessionId).map(\.scope), [.worker])
    }
}

/// A rostered session runs without the elapsed and idle caps; the token cap still applies.
@MainActor
final class RosteredCapExemptionTests: XCTestCase {
    private let caps = CapLimits(maxTokens: 1_000, maxWallClockSeconds: 1, maxIdleSeconds: 1)

    func testAnUnrosteredSessionKeepsBothTimeCaps() {
        let limits = WorkerSupervisor.exempting(caps, rostered: false)
        XCTAssertEqual(limits, caps)
    }

    func testARosteredSessionLosesBothTimeCapsButKeepsTheTokenCap() {
        let limits = WorkerSupervisor.exempting(caps, rostered: true)
        XCTAssertNil(limits.maxWallClockSeconds)
        XCTAssertNil(limits.maxIdleSeconds)
        XCTAssertEqual(limits.maxTokens, 1_000)
    }

    func testANilTimeLimitCanNeverBreach() {
        let breach = CapEvaluator.evaluate(
            totals: UsageTotals(inputTokens: 1, outputTokens: 1, cacheReadTokens: 0, cacheWrite5mTokens: 0),
            startedAt: Date(timeIntervalSinceNow: -86_400),
            lastActivity: Date(timeIntervalSinceNow: -86_400),
            awake: .init(nowMillis: .nowMillis),
            limits: WorkerSupervisor.exempting(caps, rostered: true)
        )
        XCTAssertNil(breach)
    }
}
