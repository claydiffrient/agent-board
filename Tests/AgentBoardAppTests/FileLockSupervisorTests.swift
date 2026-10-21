import AgentBoardBridge
import AgentBoardCore
import AgentBoardRuntime
import AgentBoardServer
import Foundation
import XCTest
@testable import AgentBoard

/// Locks against a real git repository with real spawned sessions: the corruption these prevent is
/// two agents editing one working tree, which no in-memory fixture reproduces.
@MainActor
final class FileLockSupervisorTests: XCTestCase {
    private var fixture: SupervisorFixture!
    private var sink: StoreHookSink!

    private static let quickWait = FileLockWaitPolicy(timeout: 1.0, pollInterval: 0.05)

    override func setUp() async throws {
        fixture = try SupervisorFixture.make(gitRepo: true)
        await fixture.supervisor.start()
        try XCTSkipIf(fixture.supervisor.serverPort == nil, "the board server could not bind a port")
        sink = StoreHookSink(db: fixture.db, events: SilentEventSink(), lockWait: Self.quickWait)
    }

    override func tearDown() async throws {
        await fixture.supervisor.waitForSetup()
        await fixture.cleanUp()
        fixture = nil
        sink = nil
    }

    private var locks: FileLockStore { FileLockStore(fixture.db) }

    private func makeTask(_ title: String) throws -> BoardTask {
        try fixture.tasks.create(
            projectId: fixture.project.id, title: title, body: "Do it.", acceptance: "It works.",
            priority: nil, column: .ready, origin: .human, epicId: nil
        )
    }

    private func assign(_ task: BoardTask) async throws -> AgentSession {
        try await fixture.supervisor.assign(taskId: task.id)
        await fixture.supervisor.waitForSetup()
        return try XCTUnwrap(fixture.sessions.forTask(task.id).last)
    }

    private func write(_ relative: String, session: AgentSession) async -> HookDecision? {
        let identity = TokenIdentity(
            token: "worker-\(session.sessionId)", scope: .worker, projectId: fixture.project.id,
            sessionId: session.sessionId, taskId: session.taskId
        )
        let event = HookEvent(
            name: "PreToolUse", sessionId: session.sessionId, toolName: "Edit",
            toolFilePath: (session.worktreePath ?? fixture.project.repoPath) + "/" + relative,
            rawJSON: "{}"
        )
        return await sink.handle(event, identity: identity)
    }

    /// A process that died holding locks: the rows survive it, and the next launch has to clear them
    /// or the checkout stays claimed by nobody. A detached worker that outlived the app must not be
    /// swept with them.
    func testStaleLocksAreSweptWhenTheSupervisorIsRebuiltOverTheSameDatabase() async throws {
        try fixture.setWorktreeStrategy(.shared, maxAgents: 2)
        let live = try await assign(try makeTask("Still running"))
        _ = await write("live.swift", session: live)

        let crashed = try makeTask("Crashed")
        let crashedSession = AgentSession(
            sessionId: "crashed-session", projectId: fixture.project.id, taskId: crashed.id, role: .worker,
            cwd: fixture.project.repoPath, state: .running
        )
        try fixture.sessions.insert(crashedSession)
        try locks.acquire(
            projectId: fixture.project.id, path: "crashed.swift", sessionId: "crashed-session", taskId: crashed.id
        )
        // The app died; the row it left behind says stopped, and nothing released its lock.
        try fixture.sessions.setState("crashed-session", .stopped, endedAt: .nowMillis)
        let projectId = fixture.project.id
        try await fixture.db.writer.write { db in
            try db.execute(
                sql: "INSERT INTO file_lock (project_id, path, session_id, task_id, held_since) VALUES (?, ?, ?, NULL, ?)",
                arguments: [projectId, "ghost.swift", "session-that-no-longer-exists", Int64.nowMillis]
            )
        }
        XCTAssertEqual(try locks.held(projectId: fixture.project.id).count, 3)

        let relaunched = fixture.relaunchedSupervisor()
        await relaunched.start()

        XCTAssertEqual(
            try locks.held(projectId: fixture.project.id).map(\.path), ["live.swift"],
            "the launch sweep either kept a dead agent's lock or dropped a live one"
        )
    }

    /// The idle cap kills a worker that has made no tool call for `maxIdleSeconds`. A worker held at
    /// a lock has made no tool call because Agent Board is holding it, and killing it would throw
    /// away the work the lock exists to protect. The matching stall-indicator guarantee is a pure
    /// value test: Core `AttentionSelectionTests.testOnlyRunningSessionsCanStall`.
    func testAWaitingWorkerSurvivesTheIdleCap() async throws {
        try fixture.setWorktreeStrategy(.shared, maxAgents: 2)
        let session = try await assign(try makeTask("Waiting"))
        try fixture.sessions.setState(session.sessionId, .waitingOnLock)
        let longIdle = Int64.nowMillis - 600_000
        try fixture.sessions.recordActivity(session.sessionId, at: longIdle, lastTool: "Edit")

        let current = try XCTUnwrap(fixture.sessions.get(session.sessionId))
        XCTAssertNil(
            CapEvaluator.evaluate(
                totals: .zero, startedAt: current.startedDate, lastActivity: current.lastActivityDate,
                awake: .init(now: Date()), limits: CapLimits(maxTokens: nil, maxWallClockSeconds: 1800, maxIdleSeconds: 300),
                state: current.state
            ),
            "a worker waiting on a file lock breached the idle cap"
        )
    }
}

private actor SilentEventSink: BoardEventSink {
    func notify(projectId: String, title: String, body: String) async {}
    func notify(projectId: String, sessionId: String?, title: String, body: String) async {}
    func orchestratorTurnEnded(projectId: String, sessionId: String) async {}
    func reportQueued(projectId: String) async {}
    func orchestratorCompacted(projectId: String, sessionId: String, manual: Bool) async {}
    func workerAcknowledgedShutdown(projectId: String, sessionId: String) async {}
}
