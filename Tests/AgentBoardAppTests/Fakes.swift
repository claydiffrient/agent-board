import AgentBoardBridge
import AgentBoardCore
import AgentBoardRuntime
import AgentBoardServer
import Foundation
@testable import AgentBoard

actor FakeRuntime: AgentRuntime {
    private(set) var stopped: [String] = []
    private(set) var resumed: [String] = []

    func spawn(_ request: SpawnRequest) async throws -> SpawnedAgent {
        SpawnedAgent(shortId: "short", sessionId: "session")
    }

    func resume(sessionId: String, cwd: URL, prompt: String) async throws -> SpawnedAgent {
        resumed.append(sessionId)
        return SpawnedAgent(shortId: "short-\(sessionId)", sessionId: sessionId)
    }

    func stop(shortId: String) async throws { stopped.append(shortId) }
    func remove(shortId: String) async throws {}
    func listSessions() async throws -> [AgentInfo] { [] }
    nonisolated func attachCommand(shortId: String) -> (executable: String, arguments: [String]) {
        ("claude", ["attach", shortId])
    }
}

@MainActor
struct SupervisorFixture {
    let db: AppDatabase
    let project: Project
    let supervisor: WorkerSupervisor
    let runtime: FakeRuntime
    let resolver: StoreTokenResolver
    let supportDir: URL

    var tasks: TaskStore { TaskStore(db) }
    var sessions: SessionStore { SessionStore(db) }
    var grants: TokenGrantStore { TokenGrantStore(db) }

    static func make() throws -> SupervisorFixture {
        let db = try AppDatabase.inMemory()
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentboard-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let project = try ProjectStore(db).register(
            name: "Demo",
            repoPath: supportDir.appendingPathComponent("repo").path,
            baseBranch: "main",
            worktreeRoot: supportDir.appendingPathComponent("worktrees").path,
            memoryDir: nil
        )
        let sink = LateBoundSink()
        let server = BoardServer(
            tokens: StoreTokenResolver(db: db),
            hooks: StoreHookSink(db: db, events: sink),
            tools: ScopedToolHandler(
                worker: WorkerToolHandler(db: db, events: sink),
                orchestrator: OrchestratorToolHandler(db: db, control: sink, events: sink)
            )
        )
        let runtime = FakeRuntime()
        let supervisor = WorkerSupervisor(db: db, runtime: runtime, server: server, appSupportDir: supportDir)
        sink.target = supervisor
        return SupervisorFixture(
            db: db, project: project, supervisor: supervisor, runtime: runtime,
            resolver: StoreTokenResolver(db: db), supportDir: supportDir
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: supportDir)
    }

    /// A running worker session for a fresh task, holding a bound, unrevoked grant.
    func workerAtWork(_ title: String = "Do the thing") throws -> (task: BoardTask, sessionId: String, token: String) {
        let task = try tasks.create(
            projectId: project.id, title: title, body: nil, acceptance: nil, priority: nil,
            column: .ready, origin: .human, epicId: nil
        )
        let sessionId = "session-\(UUID().uuidString)"
        try sessions.insert(AgentSession(
            sessionId: sessionId,
            shortId: "short-\(sessionId)",
            projectId: project.id,
            taskId: task.id,
            role: .worker,
            worktreePath: supportDir.appendingPathComponent("worktrees/\(task.id)").path,
            branch: "agentboard/\(task.id)",
            cwd: supportDir.path,
            state: .running
        ))
        let grant = try grants.issue(projectId: project.id, scope: .worker, taskId: task.id)
        try grants.bind(token: grant.token, sessionId: sessionId)
        return (task, sessionId, grant.token)
    }
}
