import AgentBoardBridge
import AgentBoardCore
import AgentBoardRuntime
import AgentBoardServer
import Foundation
import XCTest
@testable import AgentBoard

/// `spawn_worker` answers once the worktree is on disk and the task is claimed; the agent's own
/// start-up finishes afterwards, because on a large repository it outlasts the MCP call.
@MainActor
final class SetupHandoffTests: XCTestCase {
    private var fixture: SupervisorFixture!

    private var reports: ReportStore { ReportStore(fixture.db) }

    override func setUp() async throws {
        fixture = try SupervisorFixture.make(gitRepo: true)
        await fixture.supervisor.start()
        try XCTSkipIf(fixture.supervisor.serverPort == nil, "the board server could not bind a port")
    }

    override func tearDown() async throws {
        await fixture.runtime.releaseSpawn()
        await fixture.supervisor.waitForSetup()
        fixture.cleanUp()
        fixture = nil
    }

    private func readyTask(_ title: String = "Do the thing") throws -> BoardTask {
        try fixture.tasks.create(
            projectId: fixture.project.id, title: title, body: "Do it.", acceptance: "It works.",
            priority: nil, column: .ready, origin: .human, epicId: nil
        )
    }

    private func sessions(for task: BoardTask) throws -> [AgentSession] {
        try fixture.sessions.forTask(task.id)
    }

    func testAssignReturnsWhileSetupIsStillRunning() async throws {
        let task = try readyTask()
        await fixture.runtime.holdSpawn()

        try await fixture.supervisor.assign(taskId: task.id)

        let agentsStarted = await fixture.runtime.spawns
        XCTAssertTrue(agentsStarted.isEmpty, "assign answered only after the agent had started")
        await fixture.runtime.waitUntilSettingUp()
        let stillSettingUp = await fixture.runtime.isSettingUp
        XCTAssertTrue(stillSettingUp, "setup finished before the assertions could run")

        let session = try XCTUnwrap(sessions(for: task).first)
        XCTAssertEqual(session.state, .setup)
        XCTAssertNil(session.shortId)
        XCTAssertEqual(try fixture.tasks.get(task.id)?.column, .running)
        let worktree = try XCTUnwrap(session.worktreePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree), "the worktree is not on disk yet")
        XCTAssertTrue(
            try SupervisorFixture.git(["rev-parse", "--verify", "agentboard/\(task.id)"], cwd: fixture.repo)
                .trimmingCharacters(in: .whitespacesAndNewlines).count > 0
        )
    }

    /// The literal complaint: setup outruns the MCP call timeout on a large repository.
    func testAssignDoesNotWaitOutASleepingSetup() async throws {
        let task = try readyTask()
        await fixture.runtime.delaySpawn(.seconds(2))

        let startedAt = Date()
        try await fixture.supervisor.assign(taskId: task.id)
        let answeredIn = Date().timeIntervalSince(startedAt)

        XCTAssertLessThan(answeredIn, 1, "assign sat through the 2s setup before answering")
        XCTAssertEqual(try XCTUnwrap(sessions(for: task).first).state, .setup)

        await fixture.supervisor.waitForSetup()
        XCTAssertEqual(try XCTUnwrap(sessions(for: task).first).state, .starting)
    }

    func testTheSetupRowBecomesTheRealSessionOnceSetupFinishes() async throws {
        let task = try readyTask()
        await fixture.runtime.holdSpawn()
        try await fixture.supervisor.assign(taskId: task.id)
        let placeholder = try XCTUnwrap(sessions(for: task).first).sessionId

        await fixture.runtime.releaseSpawn()
        await fixture.supervisor.waitForSetup()

        let promoted = try XCTUnwrap(sessions(for: task).first)
        XCTAssertEqual(try sessions(for: task).count, 1, "the placeholder row outlived its own promotion")
        XCTAssertNotEqual(promoted.sessionId, placeholder)
        XCTAssertEqual(promoted.state, .starting)
        XCTAssertEqual(promoted.shortId, "short-1")
        XCTAssertEqual(promoted.attempt, 1)
        XCTAssertNil(try fixture.sessions.get(placeholder))
        let bound = try fixture.grants.forSession(promoted.sessionId)
        XCTAssertEqual(bound.count, 1, "the worker's token never bound to the promoted session")
    }

    /// A slot is a slot whether or not the worker can do anything with it yet.
    func testASessionInSetupCountsAgainstTheConcurrencyCap() async throws {
        var settings = fixture.project.settings
        settings.caps.maxConcurrentWorkers = 1
        try ProjectStore(fixture.db).updateSettings(fixture.project.id, settings)

        await fixture.runtime.holdSpawn()
        try await fixture.supervisor.assign(taskId: try readyTask("First").id)

        XCTAssertEqual(
            try CapCheck(fixture.db).canSpawn(projectId: fixture.project.id),
            .refused(reason: "1 of 1 concurrent workers already running")
        )
        let second = try readyTask("Second")
        do {
            try await fixture.supervisor.assign(taskId: second.id)
            XCTFail("the cap let a second worker through while the first was still in setup")
        } catch {
            XCTAssertTrue("\(error)".contains("concurrent workers"), "\(error)")
        }
        XCTAssertEqual(try fixture.tasks.get(second.id)?.column, .ready)
    }

    func testSetupFailingAfterTheReturnReachesTheOrchestrator() async throws {
        let task = try readyTask()
        await fixture.runtime.holdSpawn()
        await fixture.runtime.failNextSpawn(AgentRuntimeError("yarn install exited 1"))

        try await fixture.supervisor.assign(taskId: task.id)
        XCTAssertEqual(try fixture.tasks.get(task.id)?.column, .running)
        XCTAssertTrue(try reports.unconsumed(projectId: fixture.project.id).isEmpty)

        await fixture.runtime.releaseSpawn()
        await fixture.supervisor.waitForSetup()

        let stranded = try XCTUnwrap(fixture.tasks.get(task.id))
        XCTAssertEqual(stranded.column, .ready, "the task stayed in running behind a session that never started")
        XCTAssertTrue(stranded.failed)

        let session = try XCTUnwrap(sessions(for: task).first)
        XCTAssertEqual(session.state, .failed)
        XCTAssertNotNil(session.endedAt)

        let report = try XCTUnwrap(reports.unconsumed(projectId: fixture.project.id).first)
        XCTAssertEqual(report.kind, .failed)
        XCTAssertEqual(report.taskId, task.id)
        XCTAssertTrue(report.body.contains("yarn install exited 1"), report.body)
        XCTAssertTrue(report.body.contains("back in ready"), report.body)
        XCTAssertTrue(try fixture.grants.forSession(session.sessionId).isEmpty)
    }

    /// The background half of a spawn dies with the process, so the row it was going to resolve
    /// would otherwise hold its task in `running` forever.
    func testASetupInterruptedByAQuitIsFailedOnNextLaunch() async throws {
        let task = try readyTask()
        await fixture.runtime.holdSpawn()
        try await fixture.supervisor.assign(taskId: task.id)

        let restarted = WorkerSupervisor(
            db: fixture.db,
            runtime: fixture.runtime,
            server: BoardServer(
                tokens: StoreTokenResolver(db: fixture.db),
                hooks: StoreHookSink(db: fixture.db, events: LateBoundSink()),
                tools: ScopedToolHandler(
                    worker: WorkerToolHandler(db: fixture.db, control: LateBoundSink(), events: LateBoundSink()),
                    orchestrator: OrchestratorToolHandler(db: fixture.db, control: LateBoundSink(), events: LateBoundSink()),
                    reviewer: ReviewerToolHandler(db: fixture.db, control: LateBoundSink(), events: LateBoundSink())
                )
            ),
            appSupportDir: fixture.supportDir,
            worktreeBase: fixture.worktreeBase,
            projectsRoot: fixture.supportDir.appendingPathComponent("claude-projects")
        )
        await restarted.start()

        XCTAssertEqual(try fixture.tasks.get(task.id)?.column, .ready)
        XCTAssertEqual(try XCTUnwrap(sessions(for: task).first).state, .failed)
        let report = try XCTUnwrap(reports.unconsumed(projectId: fixture.project.id).first)
        XCTAssertTrue(report.body.contains("Agent Board quit while the worktree was still being set up"), report.body)
    }

    /// Nothing to kill yet, but the task must not be left in `running` behind the dead row.
    func testStoppingAWorkerMidSetupPutsItsTaskBack() async throws {
        let task = try readyTask()
        await fixture.runtime.holdSpawn()
        try await fixture.supervisor.assign(taskId: task.id)
        let placeholder = try XCTUnwrap(sessions(for: task).first).sessionId

        try await fixture.supervisor.stop(sessionId: placeholder)

        XCTAssertEqual(try XCTUnwrap(fixture.sessions.get(placeholder)).state, .stopped)
        XCTAssertEqual(try fixture.tasks.get(task.id)?.column, .ready)
        XCTAssertEqual(try fixture.tasks.get(task.id)?.failed, false)

        // The agent that comes up afterwards has no row to belong to, so it is stopped again.
        await fixture.runtime.releaseSpawn()
        await fixture.supervisor.waitForSetup()
        let stopped = await fixture.runtime.stopped
        XCTAssertEqual(stopped, ["short-1"])
        XCTAssertEqual(try sessions(for: task).count, 1, "the promoted session outlived the stop")
    }

    /// Its id is Agent Board's own placeholder, which `claude agents` cannot list.
    func testReconcileLeavesASessionInSetupAlone() async throws {
        let task = try readyTask()
        await fixture.runtime.holdSpawn()
        try await fixture.supervisor.assign(taskId: task.id)

        await fixture.supervisor.reconcile(projectId: fixture.project.id)

        XCTAssertEqual(try XCTUnwrap(sessions(for: task).first).state, .setup)
        XCTAssertEqual(try fixture.tasks.get(task.id)?.column, .running)
    }
}
