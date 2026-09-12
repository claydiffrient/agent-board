import AgentBoardBridge
import AgentBoardCore
import AgentBoardRuntime
import AgentBoardServer
import Foundation
import Observation

enum SupervisorError: LocalizedError {
    case notAGitRepository(String)
    case projectNotFound(String)
    case taskNotFound(String)
    case sessionNotFound(String)
    case sessionHasNoShortId(String)
    case taskNotAssignable(title: String, column: TaskColumn)
    case capRefused(String)
    case serverNotRunning
    case spawnFailed(worktree: String, underlying: String)
    case approvalNotFound(String)

    var errorDescription: String? {
        switch self {
        case .approvalNotFound(let id): return "approval \(id) not found"
        case .notAGitRepository(let path): return "\(path) is not a git repository"
        case .projectNotFound(let id): return "project \(id) not found"
        case .taskNotFound(let id): return "task \(id) not found"
        case .sessionNotFound(let id): return "session \(id) not found"
        case .sessionHasNoShortId(let id): return "session \(id) has no claude short id yet; reconcile first"
        case .taskNotAssignable(let title, let column): return "\"\(title)\" is in \(column.rawValue) and cannot be assigned"
        case .capRefused(let reason): return "spawn refused: \(reason)"
        case .serverNotRunning: return "the Agent Board server is not running"
        case .spawnFailed(let worktree, let underlying):
            return "spawn failed; worktree kept at \(worktree) for retry.\n\(underlying)"
        }
    }
}

@MainActor
@Observable
final class WorkerSupervisor: WorkerSupervising, WorkerControl, BoardEventSink {
    private(set) var serverPort: Int?
    private(set) var lastError: String?

    @ObservationIgnored private let db: AppDatabase
    @ObservationIgnored private let runtime: any AgentRuntime
    @ObservationIgnored private let server: BoardServer
    @ObservationIgnored private let appSupportDir: URL
    @ObservationIgnored private let projects: ProjectStore
    @ObservationIgnored private let tasks: TaskStore
    @ObservationIgnored private let sessions: SessionStore
    @ObservationIgnored private let grants: TokenGrantStore
    @ObservationIgnored private let hookEvents: HookEventStore
    @ObservationIgnored private let approvals: ApprovalStore
    @ObservationIgnored private let notes: NoteStore
    @ObservationIgnored private let epics: EpicStore
    @ObservationIgnored private let board: Board
    @ObservationIgnored private var meteringTask: _Concurrency.Task<Void, Never>?
    @ObservationIgnored private var consoles: [String: OrchestratorConsole] = [:]

    nonisolated static let taskBranchPrefix = "agentboard/"
    static let meteringInterval: Duration = .seconds(5)
    /// Sessions that ended this recently still get one more transcript read so final spend lands.
    static let finalSpendWindowMillis: Int64 = 15_000

    init(db: AppDatabase, runtime: any AgentRuntime, server: BoardServer, appSupportDir: URL) {
        self.db = db
        self.runtime = runtime
        self.server = server
        self.appSupportDir = appSupportDir
        projects = ProjectStore(db)
        tasks = TaskStore(db)
        sessions = SessionStore(db)
        grants = TokenGrantStore(db)
        hookEvents = HookEventStore(db)
        approvals = ApprovalStore(db)
        notes = NoteStore(db)
        epics = EpicStore(db)
        board = Board(db)
    }

    private var sessionConfigDir: URL { appSupportDir.appendingPathComponent("sessions") }

    func start() async {
        do {
            let portFile = appSupportDir.appendingPathComponent("server-port")
            let saved = (try? String(contentsOf: portFile, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let port = try await server.start(preferredPort: saved)
            serverPort = port
            try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
            try? "\(port)".write(to: portFile, atomically: true, encoding: .utf8)
        } catch {
            lastError = describe(error)
        }
        startMetering()
    }

    // MARK: - WorkerSupervising

    func registerProject(repoPath: URL, name: String?, baseBranch: String?) async throws -> Project {
        try await recording {
            let repo = repoPath.standardizedFileURL
            guard FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git").path) else {
                throw SupervisorError.notAGitRepository(repo.path)
            }
            if let existing = try projects.byRepoPath(repo.path) {
                return existing
            }
            let resolvedBase: String
            if let baseBranch, !baseBranch.isEmpty {
                resolvedBase = baseBranch
            } else {
                resolvedBase = try await offMain { Self.defaultBranch(repo: repo) } ?? "main"
            }
            let id = Project.newId()
            let project = Project(
                id: id,
                name: name?.isEmpty == false ? name! : repo.lastPathComponent,
                repoPath: repo.path,
                baseBranch: resolvedBase,
                worktreeRoot: appSupportDir.appendingPathComponent("worktrees/\(id)").path,
                memoryDir: ClaudeProjectPaths.memoryDir(forPath: repo.path).path,
                orchSessionId: nil,
                settingsJSON: ProjectSettings.forNewProject().encoded(),
                createdAt: .nowMillis
            )
            try insert(project)
            return project
        }
    }

    private func insert(_ project: Project) throws {
        try db.writer.write { db in try project.insert(db) }
    }

    func assign(taskId: String) async throws {
        try await recording { _ = try await spawn(taskId: taskId) }
    }

    @discardableResult
    private func spawn(taskId: String) async throws -> AgentSession {
        guard let task = try tasks.get(taskId) else { throw SupervisorError.taskNotFound(taskId) }
        guard task.column != .running, task.column != .done else {
            throw SupervisorError.taskNotAssignable(title: task.title, column: task.column)
        }
        guard let project = try projects.get(task.projectId) else {
            throw SupervisorError.projectNotFound(task.projectId)
        }
        guard let port = serverPort else { throw SupervisorError.serverNotRunning }
        if case .refused(let reason) = try CapCheck(db).canSpawn(projectId: project.id) {
            throw SupervisorError.capRefused(reason)
        }

        let attempt = try sessions.forTask(taskId).count + 1
        let branch = Self.taskBranchPrefix + taskId
        let manager = WorktreeManager(
            repoPath: URL(fileURLWithPath: project.repoPath),
            worktreeRoot: URL(fileURLWithPath: project.worktreeRoot)
        )
        let base = project.baseBranch
        let worktree = try await offMain {
            try Self.existingWorktree(manager, name: taskId) ?? manager.create(name: taskId, branch: branch, base: base)
        }

        do {
            let memoryDir = URL(fileURLWithPath: project.memoryDir ?? ClaudeProjectPaths.memoryDir(forPath: project.repoPath).path)
            _ = try ClaudeProjectPaths.linkMemory(worktreePath: worktree.path, to: memoryDir)

            let grant = try grants.issue(projectId: project.id, scope: .worker, taskId: taskId)
            let configFiles = try SessionConfigWriter.write(
                configDir: sessionConfigDir,
                configId: Self.configId(taskId: taskId, attempt: attempt),
                port: port,
                token: grant.token,
                autoModeJSON: project.settings.autoModeJSON,
                extraMcpServers: nil
            )
            let request = SpawnRequest(
                cwd: worktree,
                name: Self.sessionName(for: task),
                prompt: Self.openingPrompt(
                    task: task, branch: branch, attempt: attempt,
                    notes: try notes.notesForSpawn(
                        projectId: project.id, taskId: taskId, epicId: task.epicId
                    )
                ),
                configFiles: configFiles,
                model: task.model ?? project.settings.defaultModel
            )
            let spawned = try await runtime.spawn(request)
            try? grants.bind(token: grant.token, sessionId: spawned.sessionId)

            let session = AgentSession(
                sessionId: spawned.sessionId,
                shortId: spawned.shortId,
                projectId: project.id,
                taskId: taskId,
                role: .worker,
                worktreePath: worktree.path,
                branch: branch,
                cwd: worktree.path,
                startedAt: .nowMillis,
                attempt: attempt
            )
            let recorded = try board.assign(taskId: taskId, session: session)
            try replayEarlyHooks(sessionId: spawned.sessionId)
            return recorded
        } catch {
            throw SupervisorError.spawnFailed(worktree: worktree.path, underlying: describe(error))
        }
    }

    func stop(sessionId: String) async throws {
        try await recording {
            let session = try requireSession(sessionId)
            guard let shortId = session.shortId else { throw SupervisorError.sessionHasNoShortId(sessionId) }
            try await runtime.stop(shortId: shortId)
            try board.terminate(sessionId: sessionId, cause: .stoppedByHuman)
            try grants.revokeAll(sessionId: sessionId)
            announceReports(projectId: session.projectId)
        }
    }

    func resume(sessionId: String) async throws {
        try await recording {
            let session = try requireSession(sessionId)
            guard let port = serverPort else { throw SupervisorError.serverNotRunning }
            guard let taskId = session.taskId else { throw SupervisorError.taskNotFound("(none for session \(sessionId))") }
            guard let project = try projects.get(session.projectId) else {
                throw SupervisorError.projectNotFound(session.projectId)
            }
            let token: String
            if let grant = try grants.forSession(sessionId).first(where: { !$0.isRevoked }) {
                token = grant.token
            } else {
                let grant = try grants.issue(projectId: project.id, scope: .worker, taskId: taskId)
                try grants.bind(token: grant.token, sessionId: sessionId)
                token = grant.token
            }
            try SessionConfigWriter.write(
                configDir: sessionConfigDir,
                configId: Self.configId(taskId: taskId, attempt: session.attempt),
                port: port,
                token: token,
                autoModeJSON: project.settings.autoModeJSON,
                extraMcpServers: nil
            )
            let resumed = try await runtime.resume(
                sessionId: sessionId,
                cwd: URL(fileURLWithPath: session.cwd),
                prompt: Self.resumePrompt(previousStop: session.stopReason)
            )
            if resumed.shortId != session.shortId {
                try sessions.setShortId(sessionId, resumed.shortId)
            }
            try sessions.markResumed(sessionId)
            if let task = try tasks.get(taskId) {
                if task.failed { try tasks.setFailed(taskId, false, reason: nil) }
                if task.column != .running { try tasks.move(taskId, to: .running) }
            }
        }
    }

    func pauseAll(projectId: String) async throws {
        try await recording {
            var firstFailure: Error?
            for session in try sessions.active(projectId: projectId) where session.role == .worker {
                do {
                    guard let shortId = session.shortId else { throw SupervisorError.sessionHasNoShortId(session.sessionId) }
                    try await runtime.stop(shortId: shortId)
                    try board.terminate(sessionId: session.sessionId, cause: .stoppedByHuman)
                } catch {
                    firstFailure = firstFailure ?? error
                }
            }
            announceReports(projectId: projectId)
            if let firstFailure { throw firstFailure }
        }
    }

    func accept(taskId: String) async throws {
        try await recording {
            guard let task = try tasks.get(taskId) else { throw SupervisorError.taskNotFound(taskId) }
            guard let project = try projects.get(task.projectId) else {
                throw SupervisorError.projectNotFound(task.projectId)
            }
            try board.accept(taskId: taskId)
            let taskSessions = try sessions.forTask(taskId)
            for session in taskSessions {
                try grants.revokeAll(sessionId: session.sessionId)
            }
            announceReports(projectId: task.projectId)
            await tearDownWorktrees(of: taskSessions, task: task, project: project)
        }
    }

    func reopen(taskId: String) async throws {
        try await recording {
            let report = try board.reopen(taskId: taskId)
            announceReports(projectId: report.projectId)
        }
    }

    func discard(taskId: String) async throws {
        try await recording {
            guard let task = try tasks.get(taskId) else { throw SupervisorError.taskNotFound(taskId) }
            guard let project = try projects.get(task.projectId) else {
                throw SupervisorError.projectNotFound(task.projectId)
            }
            let taskSessions = try sessions.forTask(taskId)
            for session in taskSessions where session.state.isActive {
                if let shortId = session.shortId {
                    try? await runtime.stop(shortId: shortId)
                }
                try sessions.setState(session.sessionId, .stopped, endedAt: .nowMillis)
            }
            for session in taskSessions {
                try grants.revokeAll(sessionId: session.sessionId)
            }
            await tearDownWorktrees(of: taskSessions, task: task, project: project)
            try board.discard(taskId: taskId)
            announceReports(projectId: project.id)
        }
    }

    func reconcile(projectId: String) async {
        let listed: [AgentInfo]
        do {
            listed = try await runtime.listSessions()
        } catch {
            lastError = describe(error)
            return
        }
        guard let ours = try? sessions.all(projectId: projectId) else { return }
        /// Snapshotted before the terminate pass so a session this reconcile just declared vanished
        /// keeps its worktree for one more cycle.
        let liveWorktrees = Set(ours.filter { $0.state.isActive }.compactMap(\.worktreePath))
        var byId: [String: AgentInfo] = [:]
        for info in listed {
            if let sessionId = info.sessionId, byId[sessionId] == nil { byId[sessionId] = info }
        }
        var queuedReport = false
        for session in ours {
            guard let info = byId[session.sessionId] else {
                if session.state.isActive {
                    if session.role == .orchestrator, consoles[session.projectId]?.isProcessRunning == true {
                        continue
                    }
                    let report = (try? board.terminate(sessionId: session.sessionId, cause: .vanished)) ?? nil
                    queuedReport = queuedReport || report != nil
                }
                continue
            }
            if session.shortId == nil, let shortId = info.id {
                try? sessions.setShortId(session.sessionId, shortId)
            }
            let state = info.state?.lowercased()
            let status = info.status?.lowercased()
            if state == "stopped" || status == "stopped" {
                if session.state.isActive {
                    let report = (try? board.terminate(sessionId: session.sessionId, cause: .vanished)) ?? nil
                    queuedReport = queuedReport || report != nil
                }
            } else if status == "running" {
                if [.starting, .idle, .stopped].contains(session.state) {
                    try? sessions.setState(session.sessionId, .running)
                }
            } else if state == "done" || status == "idle" {
                if session.state == .starting || session.state == .running {
                    try? sessions.setState(session.sessionId, .idle)
                }
            }
        }
        if queuedReport { announceReports(projectId: projectId) }
        await reapOrphanedWorktrees(projectId: projectId, keeping: liveWorktrees)
    }

    func attachCommand(sessionId: String) -> (executable: String, arguments: [String])? {
        guard let shortId = try? sessions.get(sessionId)?.shortId else { return nil }
        return runtime.attachCommand(shortId: shortId)
    }

    func worktreeDiffstat(taskId: String) async -> String? {
        guard let task = try? tasks.get(taskId),
              let project = try? projects.get(task.projectId),
              let worktreePath = try? sessions.forTask(taskId)
                  .compactMap(\.worktreePath)
                  .first(where: { FileManager.default.fileExists(atPath: $0) })
        else { return nil }
        let manager = WorktreeManager(
            repoPath: URL(fileURLWithPath: project.repoPath),
            worktreeRoot: URL(fileURLWithPath: project.worktreeRoot)
        )
        let base = project.baseBranch
        return try? await offMain {
            try manager.diffstat(worktree: URL(fileURLWithPath: worktreePath), against: base)
        }
    }

    // MARK: - Worktree and branch cleanup

    /// A retried task has one worktree per attempt, so every session is torn down, not just the newest.
    private func tearDownWorktrees(of taskSessions: [AgentSession], task: BoardTask, project: Project) async {
        let paths = taskSessions.compactMap(\.worktreePath).reduce(into: [String]()) { unique, path in
            if !unique.contains(path) { unique.append(path) }
        }
        let manager = Self.worktreeManager(for: project)
        let branch = Self.taskBranchPrefix + task.id
        let bases = mergeTargets(for: task, project: project)
        let notices = await offMainNotices {
            Self.tearDown(manager: manager, paths: paths, branch: branch, bases: bases)
        }
        report(notices)
    }

    /// Sessions that failed or were stopped on a task nobody accepted or discarded leave their
    /// worktree behind, as do sessions whose task record is already gone.
    private func reapOrphanedWorktrees(projectId: String, keeping live: Set<String>) async {
        guard let project = try? projects.get(projectId) else { return }
        let manager = Self.worktreeManager(for: project)
        let bases = [project.baseBranch] + ((try? epics.list(projectId: projectId)) ?? []).map(\.branch)
        let notices = await offMainNotices {
            Self.reap(manager: manager, keeping: live, bases: bases)
        }
        report(notices)
    }

    private func mergeTargets(for task: BoardTask, project: Project) -> [String] {
        guard let epicId = task.epicId, let epic = try? epics.get(epicId) else { return [project.baseBranch] }
        return [project.baseBranch, epic.branch]
    }

    private static func worktreeManager(for project: Project) -> WorktreeManager {
        WorktreeManager(
            repoPath: URL(fileURLWithPath: project.repoPath),
            worktreeRoot: URL(fileURLWithPath: project.worktreeRoot)
        )
    }

    private nonisolated static func tearDown(
        manager: WorktreeManager, paths: [String], branch: String, bases: [String]
    ) -> [String] {
        var notices: [String] = []
        var removedEvery = true
        for path in paths where FileManager.default.fileExists(atPath: path) {
            switch removeIfClean(manager, at: URL(fileURLWithPath: path)) {
            case .removed(let diagnostics):
                notices.append(contentsOf: diagnostics)
            case .kept(let reason):
                notices.append(reason)
                removedEvery = false
            }
        }
        guard removedEvery else { return notices }
        notices.append(contentsOf: deleteBranch(manager, branch, bases: bases))
        return notices
    }

    private nonisolated static func reap(
        manager: WorktreeManager, keeping live: Set<String>, bases: [String]
    ) -> [String] {
        guard let listed = try? manager.list() else { return [] }
        let root = resolved(manager.worktreeRoot.path)
        let liveRoots = Set(live.map(resolved))
        var notices: [String] = []
        for info in listed where !info.isBare {
            let path = resolved(info.path.path)
            guard path.hasPrefix(root + "/"), !liveRoots.contains(path) else { continue }
            if info.branch?.hasPrefix(EpicStore.branchPrefix) == true { continue }
            do {
                if try manager.hasUnmergedCommits(worktree: info.path, bases: bases) {
                    notices.append("kept orphaned worktree \(path): it has commits that are not in \(bases.joined(separator: " or "))")
                    continue
                }
            } catch {
                notices.append("kept orphaned worktree \(path): its merge status could not be read (\(error))")
                continue
            }
            switch removeIfClean(manager, at: info.path) {
            case .removed(let diagnostics):
                notices.append(contentsOf: diagnostics)
                if let branch = info.branch {
                    notices.append(contentsOf: deleteBranch(manager, branch, bases: bases))
                }
            case .kept(let reason):
                notices.append(reason)
            }
        }
        notices.append(contentsOf: sweepMergedBranches(manager, bases: bases))
        return notices
    }

    /// Task branches outlive their worktree: every accepted task before this swept them up leaves one
    /// behind. Only failures are reported, since an unmerged branch is the normal in-flight state.
    private nonisolated static func sweepMergedBranches(_ manager: WorktreeManager, bases: [String]) -> [String] {
        guard let branches = try? manager.localBranches(withPrefix: taskBranchPrefix) else { return [] }
        return branches
            .filter { !$0.hasPrefix(EpicStore.branchPrefix) }
            .flatMap { branch -> [String] in
                do {
                    _ = try manager.deleteBranchIfMerged(branch, into: bases)
                    return []
                } catch {
                    return ["could not delete branch \(branch): \(error)"]
                }
            }
    }

    private enum WorktreeTeardown {
        case removed([String])
        case kept(String)
    }

    private nonisolated static func removeIfClean(_ manager: WorktreeManager, at path: URL) -> WorktreeTeardown {
        do {
            if try manager.hasUncommittedChanges(worktree: path) {
                return .kept("kept worktree \(path.path): it has uncommitted changes")
            }
            return .removed(try manager.remove(path: path).hookDiagnostics)
        } catch {
            return .kept("could not remove worktree \(path.path): \(error)")
        }
    }

    private nonisolated static func deleteBranch(
        _ manager: WorktreeManager, _ branch: String, bases: [String]
    ) -> [String] {
        do {
            if case .kept(let branch, let reason) = try manager.deleteBranchIfMerged(branch, into: bases) {
                return ["kept branch \(branch): \(reason)"]
            }
            return []
        } catch {
            return ["could not delete branch \(branch): \(error)"]
        }
    }

    private nonisolated static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func offMainNotices(_ body: @escaping @Sendable () -> [String]) async -> [String] {
        await _Concurrency.Task.detached(priority: .userInitiated) { body() }.value
    }

    /// Cleanup notices share the status bar's error slot; nothing else surfaces them to the human.
    private func report(_ notices: [String]) {
        guard !notices.isEmpty else { return }
        lastError = notices.joined(separator: "\n")
    }

    // MARK: - Orchestrator and approvals

    func orchestratorConsole(projectId: String) throws -> OrchestratorConsole {
        if let existing = consoles[projectId] { return existing }
        guard try projects.get(projectId) != nil else { throw SupervisorError.projectNotFound(projectId) }
        let console = OrchestratorConsole(
            projectId: projectId,
            db: db,
            sessionConfigDir: sessionConfigDir,
            currentPort: { [weak self] in self?.serverPort }
        )
        consoles[projectId] = console
        return console
    }

    func approve(approvalId: String) async throws {
        try await recording {
            guard let approval = try approvals.get(approvalId) else { throw SupervisorError.approvalNotFound(approvalId) }
            try board.resolveApproval(approvalId, approved: true, by: "human")
            announceReports(projectId: approval.projectId)
            if approval.kind == .spawn, let taskId = approval.taskId {
                try await spawn(taskId: taskId)
            }
        }
    }

    func deny(approvalId: String, reason: String?) async throws {
        try await recording {
            let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
            let approval = try board.resolveApproval(
                approvalId, approved: false, by: "human", reason: trimmed?.isEmpty == false ? trimmed : nil
            )
            announceReports(projectId: approval.projectId)
        }
    }

    func promote(taskId: String) async throws {
        try await recording {
            guard let task = try tasks.get(taskId) else { throw SupervisorError.taskNotFound(taskId) }
            try board.promote(taskId: taskId)
            announceReports(projectId: task.projectId)
        }
    }

    // MARK: - WorkerControl

    func spawnWorker(taskId: String) async throws -> String {
        try await recording { try await spawn(taskId: taskId).sessionId }
    }

    func stopWorker(sessionId: String) async throws {
        try await stop(sessionId: sessionId)
    }

    // MARK: - BoardEventSink

    func notify(title: String, body: String) async {
        MacNotifier.post(title: title, body: body)
    }

    func orchestratorTurnEnded(projectId: String, sessionId: String) async {
        consoles[projectId]?.turnEnded()
    }

    func reportQueued(projectId: String) async {
        announceReports(projectId: projectId)
    }

    /// The orchestrator only learns of a queued report through the console notice.
    private func announceReports(projectId: String) {
        consoles[projectId]?.reportsChanged()
    }

    // MARK: - Metering

    private func startMetering() {
        meteringTask?.cancel()
        meteringTask = _Concurrency.Task { [weak self] in
            while !_Concurrency.Task.isCancelled {
                try? await _Concurrency.Task.sleep(for: Self.meteringInterval)
                guard let self, !_Concurrency.Task.isCancelled else { return }
                await self.meterTick()
            }
        }
    }

    private func meterTick() async {
        guard let all = try? projects.list() else { return }
        let now = Int64.nowMillis
        for project in all {
            let limits = Self.capLimits(project.settings.caps)
            guard let projectSessions = try? sessions.all(projectId: project.id) else { continue }
            for session in projectSessions where Self.shouldMeter(session, now: now) {
                await meter(session, limits: limits)
            }
        }
    }

    private static func shouldMeter(_ session: AgentSession, now: Int64) -> Bool {
        if session.state.isActive { return true }
        guard let endedAt = session.endedAt else { return false }
        return now - endedAt < finalSpendWindowMillis
    }

    private func meter(_ session: AgentSession, limits: CapLimits) async {
        var totals = UsageTotals(
            inputTokens: session.tokensIn,
            outputTokens: session.tokensOut,
            cacheReadTokens: session.cacheRead,
            cacheWrite5mTokens: session.cacheWrite
        )
        var model = session.model
        var lastActivity = session.lastActivityDate

        if let path = session.transcriptPath {
            let url = URL(fileURLWithPath: path)
            if let summary = try? await offMain({ try TranscriptMeter.summarize(transcriptAt: url) }) {
                totals = summary.totals
                model = summary.model ?? model
                if let seen = summary.lastActivity {
                    lastActivity = lastActivity.map { max($0, seen) } ?? seen
                }
                try? sessions.updateSpend(
                    session.sessionId,
                    tokensIn: totals.inputTokens,
                    tokensOut: totals.outputTokens,
                    cacheRead: totals.cacheReadTokens,
                    cacheWrite: totals.cacheWriteTokens,
                    estCostUSD: PricingTable.default.estimateUSD(model: model, totals: totals),
                    model: model
                )
            }
        }

        guard let current = try? sessions.get(session.sessionId), current.state.isActive, current.role == .worker else { return }
        guard let breach = CapEvaluator.evaluate(
            totals: totals,
            startedAt: current.startedDate,
            lastActivity: lastActivity,
            now: Date(),
            limits: limits
        ) else { return }
        if case .idle = breach, current.state == .blocked { return }
        await enforce(breach, on: current)
    }

    private func enforce(_ breach: CapBreach, on session: AgentSession) async {
        let description = Self.describe(breach)
        if let shortId = session.shortId {
            try? await runtime.stop(shortId: shortId)
        }
        _ = try? board.terminate(sessionId: session.sessionId, cause: .capBreach(description))
        announceReports(projectId: session.projectId)
        MacNotifier.post(title: "Worker stopped at cap", body: description)
    }

    private static func capLimits(_ caps: Caps) -> CapLimits {
        CapLimits(
            maxTokens: caps.maxTokensPerAgent,
            maxWallClockSeconds: caps.maxWallClockSeconds,
            maxIdleSeconds: caps.maxIdleSeconds
        )
    }

    private static func describe(_ breach: CapBreach) -> String {
        switch breach {
        case .tokens(let used, let limit):
            return "token cap reached: \(used) of \(limit) tokens"
        case .wallClock(let elapsed, let limit):
            return "wall clock cap reached: \(Int(elapsed / 60)) of \(Int(limit / 60)) minutes"
        case .idle(let since, let limit):
            let idleFor = Int(Date().timeIntervalSince(since) / 60)
            return "idle cap reached: no activity for \(idleFor) minutes (limit \(Int(limit / 60)))"
        }
    }

    // MARK: - Spawn helpers

    /// Hooks that arrived before `agent_session` existed were only logged; apply what they said.
    private func replayEarlyHooks(sessionId: String) throws {
        let events = try hookEvents.recent(sessionId: sessionId, limit: 200)
        if let start = events.last(where: { $0.event == "SessionStart" }) {
            try sessions.setState(sessionId, .running)
            if let path = Self.payloadString("transcript_path", in: start.payload) {
                try sessions.setTranscriptPath(sessionId, path)
            }
        }
        if let lastTool = events.first(where: { $0.event == "PostToolUse" }) {
            try sessions.recordActivity(sessionId, at: lastTool.at, lastTool: Self.payloadString("tool_name", in: lastTool.payload))
        }
    }

    private static func payloadString(_ key: String, in payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object[key] as? String
    }

    private nonisolated static func existingWorktree(_ manager: WorktreeManager, name: String) throws -> URL? {
        let expected = manager.worktreeRoot.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: expected.path) else { return nil }
        let expectedPath = expected.standardizedFileURL.resolvingSymlinksInPath().path
        return try manager.list()
            .first { $0.path.standardizedFileURL.resolvingSymlinksInPath().path == expectedPath }?
            .path
    }

    static func resumePrompt(previousStop: String?) -> String {
        var lines = ["Agent Board resumed this session. Continue your task from where you left off; check `git status` and `git log` first."]
        if let previousStop, !previousStop.isEmpty {
            lines.append("The previous run was stopped by Agent Board: \(previousStop).")
        }
        lines.append("When finished, follow the completion protocol from your original instructions (commit, do not push, call report_complete).")
        return lines.joined(separator: " ")
    }

    static func configId(taskId: String, attempt: Int) -> String {
        "\(taskId)-\(attempt)"
    }

    static func sessionName(for task: BoardTask) -> String {
        var slug = ""
        var pendingDash = false
        for scalar in task.title.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingDash, !slug.isEmpty { slug.append("-") }
                slug.unicodeScalars.append(scalar)
                pendingDash = false
            } else {
                pendingDash = true
            }
        }
        if slug.isEmpty { slug = String(task.id.prefix(8)) }
        return String(slug.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    static func openingPrompt(task: BoardTask, branch: String, attempt: Int, notes: [InjectedNote] = []) -> String {
        OpeningPrompt.compose(task: task, branch: branch, attempt: attempt, notes: notes)
    }

    private nonisolated static func defaultBranch(repo: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: WorktreeManager.gitPath)
        process.arguments = ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"]
        process.currentDirectoryURL = repo
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let ref = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ref.isEmpty else { return nil }
        return ref.hasPrefix("origin/") ? String(ref.dropFirst("origin/".count)) : ref
    }

    // MARK: - Plumbing

    private func requireSession(_ sessionId: String) throws -> AgentSession {
        guard let session = try sessions.get(sessionId) else { throw SupervisorError.sessionNotFound(sessionId) }
        return session
    }

    private func recording<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            lastError = describe(error)
            throw error
        }
    }

    private nonisolated func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }

    private nonisolated func offMain<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await _Concurrency.Task.detached(priority: .userInitiated) { try body() }.value
    }
}
