import AgentBoardBridge
import AgentBoardCore
import AgentBoardRuntime
import AgentBoardServer
import Foundation
import XCTest
@testable import AgentBoard

/// Shutting every project down in one action, from At a Glance. The app quits at the end of this
/// in production; nothing here calls `NSApplication.terminate` — the verdict that would trigger it
/// is `GlobalShutdown.decide`, tested as logic in `GlobalShutdownTests`.
@MainActor
final class GlobalShutdownSupervisorTests: XCTestCase {
    private var fixture: SupervisorFixture!

    private var shutdowns: ShutdownOrderStore { ShutdownOrderStore(fixture.db) }
    private var projects: ProjectStore { ProjectStore(fixture.db) }

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

    @discardableResult
    private func extraProject(_ name: String) throws -> Project {
        try projects.register(
            name: name,
            repoPath: fixture.supportDir.appendingPathComponent(name).path,
            baseBranch: "main",
            worktreeRoot: fixture.supportDir.appendingPathComponent("\(name)-worktrees").path,
            memoryDir: nil
        )
    }

    /// A worker already at work, the way the wind-down finds one.
    @discardableResult
    private func worker(in project: Project, title: String, state: SessionState = .running) throws -> AgentSession {
        let task = try fixture.tasks.create(
            projectId: project.id, title: title, body: nil, acceptance: nil, priority: nil,
            column: .running, origin: .human, epicId: nil
        )
        let session = AgentSession(
            sessionId: "session-\(UUID().uuidString)", shortId: "short-\(title)",
            projectId: project.id, taskId: task.id, role: .worker,
            branch: "agentboard/\(task.id)", cwd: fixture.supportDir.path, state: state
        )
        try fixture.sessions.insert(session)
        return session
    }

    private func outstandingProjectIds() throws -> Set<String> {
        Set(try projects.list().filter { (try? shutdowns.outstanding(projectId: $0.id)) ?? nil != nil }.map(\.id))
    }

    func testOneActionOrdersEveryProjectIncludingTheOnesWithNothingRunning() async throws {
        let busy = try extraProject("Busy")
        let idle = try extraProject("Idle")
        try worker(in: fixture.project, title: "Alpha work")
        try worker(in: busy, title: "Busy work")

        let raised = try await fixture.supervisor.requestGlobalShutdown(requestedBy: "human", reason: "end of day")

        XCTAssertEqual(raised.count, 3)
        XCTAssertEqual(try outstandingProjectIds(), Set(try projects.list().map(\.id)))
        XCTAssertTrue(
            fixture.supervisor.isShuttingDown(projectId: idle.id),
            "the project with no session was left able to spawn during the wind-down"
        )
    }

    /// The order is what refuses the spawn, so a project that had nothing running still has to
    /// carry one — otherwise the orchestrator could start a worker mid-wind-down.
    func testAnIdleProjectRefusesSpawnsOnceTheGlobalOrderIsRaised() async throws {
        let idle = try extraProject("Idle")
        let task = try fixture.tasks.create(
            projectId: idle.id, title: "Queued", body: nil, acceptance: nil, priority: nil,
            column: .ready, origin: .human, epicId: nil
        )

        try await fixture.supervisor.requestGlobalShutdown(requestedBy: "human", reason: nil)

        do {
            try await fixture.supervisor.assign(taskId: task.id)
            XCTFail("a spawn started on an idle project during the global wind-down")
        } catch {
            XCTAssertEqual((error as? SupervisorError)?.errorDescription, ShutdownOrder.refusal)
        }
        XCTAssertEqual(try fixture.tasks.get(task.id)?.column, .ready)
    }

    func testEveryRunningWorkerOnEveryProjectIsEnrolledInItsProjectsOrder() async throws {
        let busy = try extraProject("Busy")
        let alpha = try worker(in: fixture.project, title: "Alpha work")
        let beta = try worker(in: busy, title: "Busy work")

        try await fixture.supervisor.requestGlobalShutdown(requestedBy: "human", reason: nil)

        let snapshot = try GlobalShutdownStore(fixture.db).snapshot()
        XCTAssertEqual(snapshot.projectCount, 2)
        XCTAssertEqual(
            Set(GlobalShutdown.rows(snapshot, awake: .init(nowMillis: .nowMillis)).map(\.sessionId)),
            [alpha.sessionId, beta.sessionId]
        )
        XCTAssertEqual(
            Set(GlobalShutdown.rows(snapshot, awake: .init(nowMillis: .nowMillis)).compactMap(\.projectName)),
            ["Demo", "Busy"]
        )
    }

    func testCancelLiftsEveryOrderRaised() async throws {
        try extraProject("Busy")
        try extraProject("Idle")
        try worker(in: fixture.project, title: "Alpha work")
        try await fixture.supervisor.requestGlobalShutdown(requestedBy: "human", reason: nil)
        XCTAssertEqual(try outstandingProjectIds().count, 3)

        let lifted = try await fixture.supervisor.cancelGlobalShutdown(by: "human")

        XCTAssertEqual(lifted.count, 3)
        XCTAssertEqual(try outstandingProjectIds(), [], "a project was left refusing spawns after Cancel")
        XCTAssertEqual(try GlobalShutdownStore(fixture.db).snapshot(), .empty)
    }

    /// The sheet shows every standing order, including one a human raised from a project's own Stop
    /// All before opening At a Glance. Cancel has to lift that one too, or it stays on screen as a
    /// refusal with nothing explaining it.
    func testCancelAlsoLiftsAnOrderRaisedBeforeTheGlobalOne() async throws {
        let busy = try extraProject("Busy")
        try await fixture.supervisor.requestShutdown(projectId: busy.id, requestedBy: "human", reason: "stop all")
        try await fixture.supervisor.requestGlobalShutdown(requestedBy: "human", reason: nil)

        _ = try await fixture.supervisor.cancelGlobalShutdown(by: "human")

        XCTAssertEqual(try outstandingProjectIds(), [])
    }

    func testRaisingTheOrderTwiceDoesNotDuplicateIt() async throws {
        try extraProject("Busy")

        let first = try await fixture.supervisor.requestGlobalShutdown(requestedBy: "human", reason: nil)
        let second = try await fixture.supervisor.requestGlobalShutdown(requestedBy: "human", reason: nil)

        XCTAssertEqual(first.map(\.id), second.map(\.id))
        for project in try projects.list() {
            XCTAssertEqual(try shutdowns.history(projectId: project.id).count, 1, project.name)
        }
    }

    /// The task body's failure path: a worktree is on disk and the agent has not started. The
    /// wind-down must not touch that row — `failInterruptedSetups()` on the next launch is what
    /// resolves it, and it looks for a session still sitting in `setup`.
    func testASetupInFlightAtQuitTimeIsSweptBackToReadyOnTheNextLaunch() async throws {
        let task = try fixture.tasks.create(
            projectId: fixture.project.id, title: "Half-prepared", body: nil, acceptance: nil,
            priority: nil, column: .ready, origin: .human, epicId: nil
        )
        await fixture.runtime.holdSpawn()
        try await fixture.supervisor.assign(taskId: task.id)
        await fixture.runtime.waitUntilSettingUp()

        try await fixture.supervisor.requestGlobalShutdown(requestedBy: "human", reason: nil)

        let inSetup = try XCTUnwrap(fixture.sessions.forTask(task.id).first)
        XCTAssertEqual(inSetup.state, .setup, "the wind-down moved a session that was still being prepared")
        XCTAssertEqual(try fixture.tasks.get(task.id)?.column, .running)
        let order = try XCTUnwrap(shutdowns.outstanding(projectId: fixture.project.id))
        XCTAssertNil(
            try fixture.deliveries.get(orderId: order.id, sessionId: inSetup.sessionId),
            "a session with no agent behind it was enrolled and would never acknowledge"
        )

        await relaunch()

        XCTAssertEqual(
            try fixture.tasks.get(task.id)?.column, .ready,
            "the interrupted setup left its task stranded in running"
        )
        XCTAssertEqual(try XCTUnwrap(fixture.sessions.forTask(task.id).first).state, .failed)
        let report = try XCTUnwrap(ReportStore(fixture.db).unconsumed(projectId: fixture.project.id)
            .first { $0.body.contains("still being set up") })
        XCTAssertEqual(report.taskId, task.id)
    }

    /// A second supervisor over the same database, which is all the next launch is.
    private func relaunch() async {
        let sink = LateBoundSink()
        let restarted = WorkerSupervisor(
            db: fixture.db,
            runtime: fixture.runtime,
            server: BoardServer(
                tokens: StoreTokenResolver(db: fixture.db),
                hooks: StoreHookSink(db: fixture.db, events: sink),
                tools: ScopedToolHandler(
                    worker: WorkerToolHandler(db: fixture.db, events: sink),
                    orchestrator: OrchestratorToolHandler(db: fixture.db, control: sink, events: sink)
                )
            ),
            appSupportDir: fixture.supportDir,
            worktreeBase: fixture.worktreeBase,
            projectsRoot: fixture.supportDir.appendingPathComponent("claude-projects")
        )
        sink.target = restarted
        await restarted.start()
    }
}
