import AgentBoardBridge
import AgentBoardCore
import AgentBoardRuntime
import AgentBoardServer
import Foundation
@testable import AgentBoard

actor FakeRuntime: AgentRuntime {
    private(set) var stopped: [String] = []
    private(set) var removed: [String] = []
    private(set) var resumed: [String] = []
    private(set) var resumePrompts: [String] = []
    private(set) var spawns: [SpawnRequest] = []
    /// True from the moment `spawn` is entered until it answers — what a slow repository's setup
    /// looks like from the outside.
    private(set) var isSettingUp = false
    private var failure: Error?
    private var gate: CheckedContinuation<Void, Never>?
    private var delay: Duration?
    private var holdNextSpawn = false
    private var entered: [CheckedContinuation<Void, Never>] = []
    private var listed: [AgentInfo] = []

    /// The next spawn blocks inside `spawn` until `releaseSpawn()` — a setup that outlives the call.
    func holdSpawn() { holdNextSpawn = true }

    /// A setup that simply takes a long time, the way `yarn install` does.
    func delaySpawn(_ duration: Duration) { delay = duration }

    func failNextSpawn(_ error: Error) { failure = error }

    /// Returns once the held spawn is actually inside `spawn`, so a test never races its own gate.
    func waitUntilSettingUp() async {
        if isSettingUp { return }
        await withCheckedContinuation { entered.append($0) }
    }

    func releaseSpawn() {
        holdNextSpawn = false
        gate?.resume()
        gate = nil
    }

    func spawn(_ request: SpawnRequest) async throws -> SpawnedAgent {
        isSettingUp = true
        for waiter in entered { waiter.resume() }
        entered = []
        if holdNextSpawn {
            await withCheckedContinuation { gate = $0 }
        }
        if let delay {
            self.delay = nil
            try? await _Concurrency.Task.sleep(for: delay)
        }
        isSettingUp = false
        if let failure {
            self.failure = nil
            throw failure
        }
        spawns.append(request)
        return SpawnedAgent(shortId: "short-\(spawns.count)", sessionId: "session-\(spawns.count)")
    }

    func resume(sessionId: String, cwd: URL, prompt: String) async throws -> SpawnedAgent {
        resumed.append(sessionId)
        resumePrompts.append(prompt)
        return SpawnedAgent(shortId: "short-\(sessionId)", sessionId: sessionId)
    }

    /// What `claude agents --json --all` answers. A sweep may read this to skip short ids the
    /// runtime no longer carries; it must never be the source of a target.
    private var listFailure: Error?

    func listing(_ infos: [AgentInfo]) { listed = infos }
    func setListed(_ agents: [AgentInfo]) { listed = agents }
    func failListing(_ error: Error) { listFailure = error }

    /// Whether `watchedPath` was on disk at each `stop`, so a test can order a stop against a teardown.
    private(set) var watchedPathExistedAtStop: [Bool] = []
    private var watchedPath: String?

    func watch(_ path: String) { watchedPath = path }

    private var stopFailures: [String: Error] = [:]

    /// `claude stop` on this short id fails the way it does for a job that is no longer running.
    func failStop(shortId: String, _ error: Error) { stopFailures[shortId] = error }

    func stop(shortId: String) async throws {
        if let failure = stopFailures[shortId] { throw failure }
        stopped.append(shortId)
        if let watchedPath { watchedPathExistedAtStop.append(FileManager.default.fileExists(atPath: watchedPath)) }
    }
    func remove(shortId: String) async throws { removed.append(shortId) }

    func listSessions() async throws -> [AgentInfo] {
        if let listFailure { throw listFailure }
        return listed
    }
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
    let repo: URL
    /// What `SupportPaths.worktreeBase` resolves to when AGENTBOARD_SUPPORT_DIR points at `supportDir`.
    let worktreeBase: URL
    /// Stands in for `~`, so a test can assert nothing leaked into a real `~/.agentboard`.
    let fakeHome: URL

    var epics: EpicStore { EpicStore(db) }
    var approvals: ApprovalStore { ApprovalStore(db) }
    var board: Board { Board(db) }

    var tasks: TaskStore { TaskStore(db) }
    var deliveries: ShutdownDeliveryStore { ShutdownDeliveryStore(db) }
    var sessions: SessionStore { SessionStore(db) }
    var grants: TokenGrantStore { TokenGrantStore(db) }
    var reports: ReportStore { ReportStore(db) }

    /// `gitRepo` lays down a real git repository at `repoPath`, which every test that exercises
    /// spawning, worktrees, or branch teardown needs.
    static func make(
        gitRepo: Bool = false, sleepLedger: SleepLedger = SleepLedger(), sleepGuard: SleepGuard? = nil
    ) throws -> SupervisorFixture {
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
            memoryDir: supportDir.appendingPathComponent("memory").path
        )
        let sink = LateBoundSink()
        let server = BoardServer(
            tokens: StoreTokenResolver(db: db),
            hooks: StoreHookSink(db: db, events: sink),
            tools: ScopedToolHandler(
                worker: WorkerToolHandler(db: db, control: sink, events: sink),
                orchestrator: OrchestratorToolHandler(db: db, control: sink, events: sink),
                reviewer: ReviewerToolHandler(db: db, control: sink, events: sink)
            )
        )
        let runtime = FakeRuntime()
        let fakeHome = supportDir.appendingPathComponent("home")
        let worktreeBase = SupportPaths.worktreeBase(
            environment: [SupportPaths.supportDirEnvKey: supportDir.path],
            home: fakeHome
        )
        let supervisor = WorkerSupervisor(
            db: db, runtime: runtime, server: server, appSupportDir: supportDir,
            worktreeBase: worktreeBase,
            projectsRoot: supportDir.appendingPathComponent("claude-projects"),
            sleepLedger: sleepLedger,
            sleepGuard: sleepGuard
        )
        sink.target = supervisor
        return SupervisorFixture(
            db: db, project: project, supervisor: supervisor, runtime: runtime,
            resolver: StoreTokenResolver(db: db), supportDir: supportDir, repo: repo,
            worktreeBase: worktreeBase, fakeHome: fakeHome
        )
    }

    func setWorktreeStrategy(_ strategy: WorktreeStrategy, maxAgents: Int? = nil) throws {
        var settings = project.settings
        settings.worktreeStrategy = strategy
        if let maxAgents { settings.sharedCheckoutMaxAgents = maxAgents }
        try ProjectStore(db).updateSettings(project.id, settings)
    }

    /// A second supervisor over the same database and support directory: what the next launch of
    /// the app builds, with everything the previous one wrote still on disk and in the tables.
    func relaunchedSupervisor() -> WorkerSupervisor {
        let sink = LateBoundSink()
        let server = BoardServer(
            tokens: StoreTokenResolver(db: db),
            hooks: StoreHookSink(db: db, events: sink),
            tools: ScopedToolHandler(
                worker: WorkerToolHandler(db: db, control: sink, events: sink),
                orchestrator: OrchestratorToolHandler(db: db, control: sink, events: sink),
                reviewer: ReviewerToolHandler(db: db, control: sink, events: sink)
            )
        )
        let supervisor = WorkerSupervisor(
            db: db, runtime: runtime, server: server, appSupportDir: supportDir,
            worktreeBase: worktreeBase,
            projectsRoot: supportDir.appendingPathComponent("claude-projects")
        )
        sink.target = supervisor
        return supervisor
    }

    var manager: WorktreeManager {
        WorktreeManager(
            repoPath: URL(fileURLWithPath: project.repoPath),
            worktreeRoot: URL(fileURLWithPath: project.worktreeRoot),
            hookSettingsURL: supportDir.appendingPathComponent("no-hooks.json"),
            attribution: .ledger(TaskCommitStore(db))
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
        process.arguments = ["-c", "user.email=test@example.com", "-c", "user.name=Test",
                             "-c", "commit.gpgsign=false"] + args
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

    func git(_ args: [String], cwd: URL? = nil) throws -> String {
        try Self.git(args, cwd: cwd ?? repo)
    }

    /// An epic with `titles` as its tasks, each already in `done` with a real branch carrying one
    /// commit — the state §5.2 step 1 requires before integration is requested.
    func epicReadyForIntegration(
        _ titles: [String],
        dependsOn: [Int: [Int]] = [:],
        goal: String? = "make it fast"
    ) throws -> (epic: Epic, tasks: [BoardTask]) {
        let specs = titles.enumerated().map { NewEpicTask(title: $0.element, dependsOn: dependsOn[$0.offset] ?? []) }
        let (epic, created) = try board.createEpic(projectId: project.id, title: "Ship search", goal: goal, tasks: specs)
        try git(["branch", epic.branch, "main"])
        for task in created {
            let branch = "agentboard/\(task.id)"
            try git(["branch", branch, epic.branch])
            try commitOn(branch: branch, message: "Work on \(task.title)")
            try TaskStore(db).move(task.id, to: .done)
        }
        try epics.setState(epic.id, .active)
        return (epic, created)
    }

    /// A commit with the branch's existing tree, so the branch diverges from the epic branch
    /// without any worktree checkout.
    func commitOn(branch: String, message: String) throws {
        let tree = try trimmed(git(["rev-parse", "\(branch)^{tree}"]))
        let parent = try trimmed(git(["rev-parse", branch]))
        let commit = try trimmed(git(["commit-tree", tree, "-p", parent, "-m", message]))
        try git(["branch", "-f", branch, commit])
    }

    /// Fast-forwards the epic branch onto `branch`, the state a previous integration run leaves behind.
    func markMerged(epic: Epic, branch: String) throws {
        try git(["branch", "-f", epic.branch, branch])
    }

    private func trimmed(_ output: String) -> String {
        output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func setGraceSeconds(_ seconds: Int) throws {
        var settings = project.settings
        settings.caps.shutdownGraceSeconds = seconds
        try ProjectStore(db).updateSettings(project.id, settings)
    }

    /// Backdates the enrollment so a grace period can expire without the test sleeping through it.
    func age(orderId: String, sessionId: String, bySeconds: Int) throws {
        try db.writer.write { db in
            try db.execute(
                sql: "UPDATE shutdown_delivery SET ordered_at = ordered_at - ? WHERE order_id = ? AND session_id = ?",
                arguments: [Int64(bySeconds) * 1000, orderId, sessionId]
            )
        }
    }

    func cleanUp() {
        let worktreeRoot = URL(fileURLWithPath: project.worktreeRoot)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: worktreeRoot.path)) ?? []
        for name in names {
            let worktree = worktreeRoot.appendingPathComponent(name).path
            try? FileManager.default.removeItem(at: ClaudeProjectPaths.projectDir(forPath: worktree))
        }
        try? FileManager.default.removeItem(at: supportDir)
    }

    /// A worker tool handler wired to this fixture's supervisor, so a tool call reaches the same
    /// event path the real server uses rather than a sink that drops everything.
    func workerHandler() -> WorkerToolHandler {
        let sink = LateBoundSink()
        sink.target = supervisor
        return WorkerToolHandler(db: db, control: sink, events: sink)
    }

    /// Stands in for `BoardServer`: the handler answers first, and work it deferred — stopping the
    /// session that is waiting on that answer — runs only afterwards.
    @discardableResult
    func callWorkerTool(_ name: String, arguments: JSONValue, token: String) async throws -> ToolResult {
        let result = try await workerHandler().call(
            name, arguments: arguments, identity: try await identity(token: token)
        )
        await result.afterResponse?()
        return result
    }

    func identity(token: String) async throws -> TokenIdentity {
        guard let identity = await resolver.resolve(token: token) else {
            throw FixtureError("token \(token) did not resolve")
        }
        return identity
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
