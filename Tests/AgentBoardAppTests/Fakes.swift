import AgentBoardBridge
import AgentBoardCore
import AgentBoardRuntime
import AgentBoardServer
import Foundation
@testable import AgentBoard

actor FakeRuntime: AgentRuntime {
    private(set) var stopped: [String] = []
    private(set) var resumed: [String] = []
    private(set) var spawns: [SpawnRequest] = []

    func spawn(_ request: SpawnRequest) async throws -> SpawnedAgent {
        spawns.append(request)
        return SpawnedAgent(shortId: "short-\(spawns.count)", sessionId: "session-\(spawns.count)")
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

struct FixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
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

    /// `gitRepo` lays down a real git repository at `repoPath`, which every test that exercises
    /// spawning, worktrees, or branch teardown needs.
    static func make(gitRepo: Bool = false) throws -> SupervisorFixture {
        let db = try AppDatabase.inMemory()
        let supportDir = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("agentboard-tests/\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let repo = supportDir.appendingPathComponent("repo")
        if gitRepo { try initRepo(at: repo) }
        let project = try ProjectStore(db).register(
            name: "Demo",
            repoPath: repo.path,
            baseBranch: "main",
            worktreeRoot: supportDir.appendingPathComponent("worktrees").path,
            memoryDir: gitRepo ? supportDir.appendingPathComponent("memory").path : nil
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

    var manager: WorktreeManager {
        WorktreeManager(
            repoPath: URL(fileURLWithPath: project.repoPath),
            worktreeRoot: URL(fileURLWithPath: project.worktreeRoot),
            hookSettingsURL: supportDir.appendingPathComponent("no-hooks.json")
        )
    }

    static func initRepo(at repo: URL) throws {
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], cwd: repo)
        try "hello\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try git(["add", "."], cwd: repo)
        try commit("Initial commit", cwd: repo)
    }

    @discardableResult
    static func git(_ args: [String], cwd: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: WorktreeManager.gitPath)
        process.arguments = args
        process.currentDirectoryURL = cwd
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AgentRuntimeError("git \(args.joined(separator: " ")) failed: \(String(decoding: err, as: UTF8.self))")
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func commit(_ message: String, cwd: URL) throws {
        try git(
            ["-c", "user.email=test@example.com", "-c", "user.name=Test", "-c", "commit.gpgsign=false",
             "commit", "-q", "-m", message],
            cwd: cwd
        )
    }

    /// A worker that really cut a worktree on `agentboard/<task-id>`, the way `spawn` leaves things.
    @discardableResult
    func worktreeWorker(task: BoardTask, attempt: Int = 1, state: SessionState = .completed) throws -> AgentSession {
        let name = attempt == 1 ? task.id : "\(task.id)-\(attempt)"
        let branch = attempt == 1 ? "agentboard/\(task.id)" : "agentboard/\(task.id)-\(attempt)"
        let worktree = try manager.create(name: name, branch: branch, base: project.baseBranch)
        let session = AgentSession(
            sessionId: "session-\(UUID().uuidString)",
            shortId: "short-\(attempt)",
            projectId: project.id,
            taskId: task.id,
            role: .worker,
            worktreePath: worktree.path,
            branch: branch,
            cwd: worktree.path,
            state: state,
            attempt: attempt
        )
        try sessions.insert(session)
        return session
    }

    func commitInto(_ worktreePath: String, file: String = "work.txt") throws {
        let url = URL(fileURLWithPath: worktreePath)
        try "work\n".write(to: url.appendingPathComponent(file), atomically: true, encoding: .utf8)
        try Self.git(["add", "."], cwd: url)
        try Self.commit("Do the work", cwd: url)
    }

    func mergeIntoBase(_ branch: String) throws {
        let repo = URL(fileURLWithPath: project.repoPath)
        try Self.git(["-c", "user.email=test@example.com", "-c", "user.name=Test", "merge", "-q", "--no-ff", "-m", "Merge \(branch)", branch], cwd: repo)
    }

    /// Spawn writes a `~/.claude/projects/<worktree-slug>/memory` symlink outside the sandbox,
    /// so every worktree this fixture created has to be unlinked by path, not just deleted.
    func cleanUp() {
        let worktreeRoot = URL(fileURLWithPath: project.worktreeRoot)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: worktreeRoot.path)) ?? []
        for name in names {
            let worktree = worktreeRoot.appendingPathComponent(name).path
            try? FileManager.default.removeItem(at: ClaudeProjectPaths.projectDir(forPath: worktree))
        }
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
