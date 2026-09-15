import AgentBoardBridge
import AgentBoardCore
import AgentBoardRuntime
import AgentBoardServer
import AppKit
import Foundation
import Observation

enum SupervisorError: LocalizedError {
    case notAGitRepository(String)
    case projectNotFound(String)
    case epicNotFound(String)
    case taskNotFound(String)
    case sessionNotFound(String)
    case sessionHasNoShortId(String)
    case taskNotAssignable(title: String, column: TaskColumn)
    case capRefused(String)
    case shutdownOrdered
    case noShutdownOrder
    case serverNotRunning
    case spawnFailed(worktree: String, underlying: String)
    case approvalNotFound(String)

    var errorDescription: String? {
        switch self {
        case .approvalNotFound(let id): return "approval \(id) not found"
        case .epicNotFound(let id): return "epic \(id) not found"
        case .notAGitRepository(let path): return "\(path) is not a git repository"
        case .projectNotFound(let id): return "project \(id) not found"
        case .taskNotFound(let id): return "task \(id) not found"
        case .sessionNotFound(let id): return "session \(id) not found"
        case .sessionHasNoShortId(let id): return "session \(id) has no claude short id yet; reconcile first"
        case .taskNotAssignable(let title, let column): return "\"\(title)\" is in \(column.rawValue) and cannot be assigned"
        case .capRefused(let reason): return "spawn refused: \(reason)"
        case .shutdownOrdered: return ShutdownOrder.refusal
        case .noShutdownOrder: return "no shutdown order is outstanding on this project"
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
    /// Wind-down progress per project id, refreshed on every delivery, every acknowledgment and
    /// every metering tick, so the progress sheet reads it instead of polling.
    private(set) var shutdownProgress: [String: ShutdownProgress] = [:]

    @ObservationIgnored private let db: AppDatabase
    @ObservationIgnored private let runtime: any AgentRuntime
    @ObservationIgnored private let server: BoardServer
    @ObservationIgnored private let appSupportDir: URL
    @ObservationIgnored private let projectsRoot: URL
    @ObservationIgnored private let projects: ProjectStore
    @ObservationIgnored private let tasks: TaskStore
    @ObservationIgnored private let sessions: SessionStore
    @ObservationIgnored private let grants: TokenGrantStore
    @ObservationIgnored private let hookEvents: HookEventStore
    @ObservationIgnored private let approvals: ApprovalStore
    @ObservationIgnored private let shutdowns: ShutdownOrderStore
    @ObservationIgnored private let deliveries: ShutdownDeliveryStore
    @ObservationIgnored private let epics: EpicStore
    @ObservationIgnored private let notes: NoteStore
    @ObservationIgnored private let board: Board
    @ObservationIgnored private let archives: ArchiveSweep
    @ObservationIgnored private var meteringTask: _Concurrency.Task<Void, Never>?
    /// Millis of the last archive sweep; 0 means none yet, so the first tick after launch sweeps
    /// and picks up whatever came due while the app was closed.
    @ObservationIgnored private var lastArchiveSweep: Int64 = 0
    /// Sessions already announced as stalled, so the tick notifies on the transition, not every 5s.
    @ObservationIgnored private var stallNotified: Set<String> = []
    @ObservationIgnored private var consoles: [String: OrchestratorConsole] = [:]

    nonisolated static let taskBranchPrefix = "agentboard/"
    static let meteringInterval: Duration = .seconds(5)
    /// The archive policies are day-granular, so they ride the metering tick at a far coarser
    /// cadence rather than paying for a scan every 5 seconds — or a second timer.
    static let archiveSweepIntervalMillis: Int64 = 5 * 60 * 1000
    /// Sessions that ended this recently still get one more transcript read so final spend lands.
    static let finalSpendWindowMillis: Int64 = 15_000

    init(
        db: AppDatabase,
        runtime: any AgentRuntime,
        server: BoardServer,
        appSupportDir: URL,
        projectsRoot: URL = ClaudeProjectPaths.defaultProjectsRoot
    ) {
        self.db = db
        self.runtime = runtime
        self.server = server
        self.appSupportDir = appSupportDir
        self.projectsRoot = projectsRoot
        projects = ProjectStore(db)
        tasks = TaskStore(db)
        sessions = SessionStore(db)
        grants = TokenGrantStore(db)
        hookEvents = HookEventStore(db)
        approvals = ApprovalStore(db)
        shutdowns = ShutdownOrderStore(db)
        deliveries = ShutdownDeliveryStore(db)
        epics = EpicStore(db)
        notes = NoteStore(db)
        board = Board(db)
        archives = ArchiveSweep(db)
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
        try requireNoShutdown(projectId: project.id)
        if case .refused(let reason) = try CapCheck(db).canSpawn(projectId: project.id) {
            throw SupervisorError.capRefused(reason)
        }

        let attempt = try sessions.forTask(taskId).count + 1
        let branch = Self.taskBranchPrefix + taskId
        let manager = WorktreeManager(
            repoPath: URL(fileURLWithPath: project.repoPath),
            worktreeRoot: URL(fileURLWithPath: project.worktreeRoot)
        )
        let epic = try task.epicId.flatMap { try epics.get($0) }
        let base: String
        if let epic {
            let epicBranch = epic.branch
            let projectBase = project.baseBranch
            try await offMain { try manager.ensureBranch(epicBranch, from: projectBase) }
            base = epicBranch
        } else {
            base = project.baseBranch
        }
        let worktree = try await offMain {
            try Self.existingWorktree(manager, name: taskId) ?? manager.create(name: taskId, branch: branch, base: base)
        }

        do {
            let recorded = try await launch(
                LaunchPlan(
                    project: project,
                    taskId: taskId,
                    worktree: worktree,
                    branch: branch,
                    configId: Self.configId(taskId: taskId, attempt: attempt),
                    name: Self.sessionName(for: task),
                    prompt: Self.openingPrompt(
                        task: task, branch: branch, attempt: attempt, epicGoal: epic?.goal,
                        notes: try notes.notesForSpawn(
                            projectId: project.id, taskId: taskId, epicId: task.epicId
                        )
                    ),
                    model: task.model ?? project.settings.defaultModel,
                    attempt: attempt
                ),
                port: port
            )
            if let epic, epic.state == .planning {
                try epics.setState(epic.id, .active)
            }
            return recorded
        } catch {
            throw SupervisorError.spawnFailed(worktree: worktree.path, underlying: describe(error))
        }
    }

    private struct LaunchPlan {
        var project: Project
        var taskId: String
        var worktree: URL
        var branch: String
        var configId: String
        var name: String
        var prompt: String
        var model: String?
        var attempt: Int
    }

    /// §3.1 steps 3-8, shared by task workers and the epic integrator: memory symlink, generated
    /// settings and MCP config, a worker-scoped token bound to the session, and the board row.
    private func launch(_ plan: LaunchPlan, port: Int) async throws -> AgentSession {
        let project = plan.project
        let memoryDir = URL(fileURLWithPath: project.memoryDir
            ?? ClaudeProjectPaths.memoryDir(forPath: project.repoPath, projectsRoot: projectsRoot).path)
        _ = try ClaudeProjectPaths.linkMemory(worktreePath: plan.worktree.path, to: memoryDir, projectsRoot: projectsRoot)

        let grant = try grants.issue(projectId: project.id, scope: .worker, taskId: plan.taskId)
        let configFiles = try SessionConfigWriter.write(
            configDir: sessionConfigDir,
            configId: plan.configId,
            port: port,
            token: grant.token,
            autoModeJSON: project.settings.autoModeJSON,
            extraMcpServers: nil
        )
        let request = SpawnRequest(
            cwd: plan.worktree,
            name: plan.name,
            prompt: plan.prompt,
            configFiles: configFiles,
            model: plan.model
        )
        let spawned = try await runtime.spawn(request)
        let session = AgentSession(
            sessionId: spawned.sessionId,
            shortId: spawned.shortId,
            projectId: project.id,
            taskId: plan.taskId,
            role: .worker,
            worktreePath: plan.worktree.path,
            branch: plan.branch,
            cwd: plan.worktree.path,
            startedAt: .nowMillis,
            attempt: plan.attempt
        )
        let recorded = try board.assign(taskId: plan.taskId, session: session)
        // §3.1 step 8: the grant binds after the session row exists, or the foreign key rejects it.
        try grants.bind(token: grant.token, sessionId: spawned.sessionId)
        try replayEarlyHooks(sessionId: spawned.sessionId)
        return recorded
    }

    /// §5.2 step 3. The integrator is an ordinary worker on a worktree checked out on the epic
    /// branch, bound to a synthetic task so its token scope, report channel and board card are real.
    @discardableResult
    private func spawnIntegrator(epicId: String) async throws -> AgentSession {
        guard let epic = try epics.get(epicId) else { throw SupervisorError.epicNotFound(epicId) }
        guard let project = try projects.get(epic.projectId) else {
            throw SupervisorError.projectNotFound(epic.projectId)
        }
        guard let port = serverPort else { throw SupervisorError.serverNotRunning }
        try requireNoShutdown(projectId: project.id)
        if case .refused(let reason) = try CapCheck(db).canSpawn(projectId: project.id) {
            throw SupervisorError.capRefused(reason)
        }

        let manager = WorktreeManager(
            repoPath: URL(fileURLWithPath: project.repoPath),
            worktreeRoot: URL(fileURLWithPath: project.worktreeRoot)
        )
        let worktreeName = "epic-\(epicId)"
        let epicBranch = epic.branch
        let worktree = try await offMain {
            try Self.existingWorktree(manager, name: worktreeName)
                ?? manager.createForBranch(name: worktreeName, branch: epicBranch)
        }

        let members = try tasks.list(projectId: project.id, epicId: epicId, includeArchived: true)
            .filter { $0.origin != .integration }
        var deps: [String: [String]] = [:]
        for member in members {
            deps[member.id] = try tasks.deps(of: member.id)
        }
        let ordered = IntegrationPlan.order(members, deps: deps)
        let branchNames = ordered.map { IntegrationPlan.branchName(taskId: $0.id) }
        let repoState = try await offMain { () -> (merged: [String: Bool], exists: Set<String>) in
            let merged = try manager.mergeStatus(worktree: worktree, branches: branchNames)
            let exists = try branchNames.filter { try manager.branchExists($0) }
            return (merged, Set(exists))
        }
        let branches = IntegrationPlan.classify(ordered, merged: repoState.merged, exists: repoState.exists)

        let task = try board.createIntegrationTask(epicId: epicId)
        var recorded: AgentSession?
        do {
            let session = try await launch(
                LaunchPlan(
                    project: project,
                    taskId: task.id,
                    worktree: worktree,
                    branch: epicBranch,
                    configId: Self.configId(taskId: task.id, attempt: 1),
                    name: Self.sessionName(for: task),
                    prompt: IntegrationPlan.compose(epic: epic, baseBranch: project.baseBranch, branches: branches),
                    model: project.settings.defaultModel,
                    attempt: 1
                ),
                port: port
            )
            recorded = session
            try epics.setState(epicId, .integrating)
            return session
        } catch {
            if recorded == nil { try? tasks.delete(task.id) }
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
            try await resume(session, prompt: Self.resumePrompt(previousStop: session.stopReason))
        }
    }

    private func resume(_ session: AgentSession, prompt: String) async throws {
        do {
            let sessionId = session.sessionId
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
                prompt: prompt
            )
            if resumed.shortId != session.shortId {
                try sessions.setShortId(sessionId, resumed.shortId)
            }
            try sessions.markResumed(sessionId)
            if let task = try tasks.get(taskId) {
                if task.failed { try tasks.setFailed(taskId, false, reason: nil) }
                if task.column != .running { try tasks.move(taskId, to: .running) }
            }
        } catch {
            lastError = describe(error)
            throw error
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
            // Teardown runs first so `deleteBranchIfMerged` still sees the task branch as unmerged
            // and keeps it; the integrator reads the surviving branch as its ledger of what is in.
            await tearDownWorktrees(of: taskSessions, task: task, project: project)
            await mergeIntoEpicBranch(task: task, project: project)
            announceReports(projectId: task.projectId)
        }
    }

    /// §5.2: the epic branch accumulates each accepted task, so a sibling spawned afterwards branches
    /// from work that is already in. Deliberately outside the acceptance transaction — the human
    /// accepted the task, and no git failure may put it back.
    private func mergeIntoEpicBranch(task: BoardTask, project: Project) async {
        guard let epicId = task.epicId, let epic = try? epics.get(epicId) else { return }
        let manager = Self.worktreeManager(for: project)
        let taskBranch = Self.taskBranchPrefix + task.id
        let epicBranch = epic.branch
        let projectBase = project.baseBranch
        let worktreeName = "merge-\(task.id)"
        let outcome: EpicMerge
        do {
            outcome = try await offMain {
                try manager.ensureBranch(epicBranch, from: projectBase)
                return try manager.mergeIntoEpic(
                    taskBranch: taskBranch, epicBranch: epicBranch, worktreeName: worktreeName
                )
            }
        } catch {
            queueEpicMergeReport(
                task: task, epic: epic,
                body: "could not be merged into the epic branch `\(epicBranch)`: \(describe(error))"
                    + "\nThe epic branch is behind. Dispatch a task to merge `\(taskBranch)` into it by hand."
            )
            return
        }
        switch outcome {
        case .alreadyMerged, .fastForwarded, .merged, .nothingToMerge:
            return
        case .conflicted(let files):
            let listed = files.isEmpty ? "(git reported no paths)" : files.map { "- `\($0)`" }.joined(separator: "\n")
            queueEpicMergeReport(
                task: task, epic: epic,
                body: "conflicts with the epic branch `\(epicBranch)`, which is unchanged and now behind."
                    + "\n\nConflicting files:\n\(listed)"
                    + "\n\nDispatch a task to merge `\(taskBranch)` into `\(epicBranch)` and resolve these."
            )
        case .skippedCheckedOut(let path):
            queueEpicMergeReport(
                task: task, epic: epic,
                body: "was not merged into the epic branch `\(epicBranch)`: that branch is checked out at \(path)."
                    + "\nWhoever holds it — the integrator, normally — must merge `\(taskBranch)` themselves."
            )
        }
    }

    private func queueEpicMergeReport(task: BoardTask, epic: Epic, body: String) {
        let text = "Task \(task.id) (\(task.title)) was accepted into done, but its branch \(body)"
        do {
            try ReportStore(db).insert(
                projectId: task.projectId, taskId: task.id, sessionId: nil, kind: .decision, body: text
            )
        } catch {
            report(["could not queue the epic merge report for \(task.id): \(describe(error))"])
            return
        }
        report(["epic \(epic.id): \(text)"])
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
        guard let context = diffContext(taskId: taskId) else { return nil }
        return try? await offMain {
            try context.manager.diffstat(worktree: context.worktree, against: context.base)
        }
    }

    func worktreeDiffSummary(taskId: String) async -> DiffSummary? {
        guard let context = diffContext(taskId: taskId) else { return nil }
        return try? await offMain {
            try context.manager.diffSummary(worktree: context.worktree, against: context.base)
        }
    }

    private func diffContext(taskId: String) -> (manager: WorktreeManager, worktree: URL, base: String)? {
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
        return (manager, URL(fileURLWithPath: worktreePath), project.baseBranch)
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
            // Before the resolve, so a refused approval is still pending once the order is cancelled.
            try requireNoShutdown(projectId: approval.projectId)
            try board.resolveApproval(approvalId, approved: true, by: "human")
            announceReports(projectId: approval.projectId)
            switch approval.kind {
            case .spawn:
                if let taskId = approval.taskId { try await spawn(taskId: taskId) }
            case .integration:
                if let epicId = approval.epicId { try await spawnIntegrator(epicId: epicId) }
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

    // MARK: - Epics

    /// SPEC §5.2 step 2: queues the human approval and nothing else. Same row `request_integration` creates.
    func requestIntegration(epicId: String) async throws {
        try await recording {
            guard try epics.get(epicId) != nil else { throw SupervisorError.epicNotFound(epicId) }
            try board.requestIntegration(epicId: epicId, requestedBy: "human")
        }
    }

    /// SPEC §5.2 step 4: opens the compare page for the human. Never creates the PR, never pushes (D8).
    @discardableResult
    func openPullRequest(epicId: String) async throws -> PullRequestOutcome {
        try await recording {
            guard let epic = try epics.get(epicId) else { throw SupervisorError.epicNotFound(epicId) }
            guard let project = try projects.get(epic.projectId) else {
                throw SupervisorError.projectNotFound(epic.projectId)
            }
            let opener = PullRequestOpener(repoPath: URL(fileURLWithPath: project.repoPath))
            let base = project.baseBranch
            let head = epic.branch
            let outcome = try await offMain { try opener.open(baseBranch: base, headBranch: head) }
            if case .openInBrowser(let url, _) = outcome {
                NSWorkspace.shared.open(url)
            }
            return outcome
        }
    }

    func promote(taskId: String) async throws {
        try await recording {
            guard let task = try tasks.get(taskId) else { throw SupervisorError.taskNotFound(taskId) }
            try board.promote(taskId: taskId)
            announceReports(projectId: task.projectId)
        }
    }

    // MARK: - Shutdown

    /// Raises the order and tells the orchestrator. Stops and signals nothing: workers already
    /// running keep going, and `pauseAll` remains the blunt path that kills them.
    @discardableResult
    func requestShutdown(projectId: String, requestedBy: String = "human", reason: String? = nil) async throws -> ShutdownOrder {
        try await recording {
            let order = try board.requestShutdown(projectId: projectId, requestedBy: requestedBy, reason: reason)
            announceReports(projectId: projectId)
            return order
        }
    }

    @discardableResult
    func cancelShutdown(projectId: String, by: String = "human") async throws -> ShutdownOrder? {
        try await recording {
            let order = try board.cancelShutdown(projectId: projectId, by: by)
            if order != nil {
                shutdownProgress[projectId] = nil
                announceReports(projectId: projectId)
            }
            return order
        }
    }

    /// Hands the outstanding order to every worker still running. A busy session is left to the
    /// `PreToolUse` deny, which is the only way in mid-turn; an idle one may never make that call,
    /// so it gets the same text as a resume prompt. Nothing is stopped here: a worker stops itself
    /// by calling `acknowledge_shutdown`, and one that never answers is counted, not killed.
    @discardableResult
    func deliverShutdownOrder(projectId: String) async throws -> ShutdownProgress {
        try await recording {
            guard let order = try shutdowns.outstanding(projectId: projectId) else {
                throw SupervisorError.noShutdownOrder
            }
            let workers = try sessions.active(projectId: projectId).filter { $0.role == .worker }
            for worker in workers {
                try deliveries.enroll(orderId: order.id, sessionId: worker.sessionId, taskId: worker.taskId)
            }
            for worker in workers where worker.state == .idle {
                await deliverByResume(order: order, to: worker)
            }
            return refreshShutdownProgress(projectId: projectId, order: order)
        }
    }

    /// Claimed before the resume runs, so a hook firing at the same moment cannot deliver the order
    /// twice. A resume that fails releases the claim for the next hook to carry.
    private func deliverByResume(order: ShutdownOrder, to session: AgentSession) async {
        let claimed = (try? deliveries.claimDelivery(
            orderId: order.id, sessionId: session.sessionId, taskId: session.taskId, via: .resume
        )) ?? false
        guard claimed else { return }
        do {
            try await resume(session, prompt: ShutdownOrder.windDownOrder(reason: order.reason, via: .resume))
        } catch {
            try? deliveries.releaseDelivery(orderId: order.id, sessionId: session.sessionId)
        }
    }

    @discardableResult
    private func refreshShutdownProgress(projectId: String, order: ShutdownOrder) -> ShutdownProgress {
        let grace = (try? projects.get(projectId))??.settings.caps.shutdownGraceSeconds
            ?? ShutdownDeliveryStore.defaultGraceSeconds
        let progress = (try? deliveries.progress(orderId: order.id, graceSeconds: grace))
            ?? ShutdownProgress(orderId: order.id, total: 0, acknowledged: 0)
        shutdownProgress[projectId] = progress
        return progress
    }

    func isShuttingDown(projectId: String) -> Bool {
        (try? shutdowns.isShuttingDown(projectId: projectId)) ?? false
    }

    private func requireNoShutdown(projectId: String) throws {
        if try shutdowns.outstanding(projectId: projectId) != nil {
            throw SupervisorError.shutdownOrdered
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

    func orchestratorCompacted(projectId: String, sessionId: String, manual: Bool) async {
        consoles[projectId]?.compactionCompleted(manual: manual)
    }

    /// The worker has committed and recorded its note; this is the orderly end of its session. The
    /// cause is neither a human kill nor a cap kill, and `terminate` puts the unfinished task back
    /// in `ready` with the note attached to the report.
    func workerAcknowledgedShutdown(projectId: String, sessionId: String) async {
        guard let session = try? sessions.get(sessionId) else { return }
        let note = try? shutdowns.outstanding(projectId: projectId)
            .flatMap { try deliveries.get(orderId: $0.id, sessionId: sessionId)?.note }
        if let shortId = session.shortId {
            try? await runtime.stop(shortId: shortId)
        }
        _ = try? board.terminate(sessionId: sessionId, cause: .shutdownAcknowledged(note: note ?? nil))
        try? grants.revokeAll(sessionId: sessionId)
        announceReports(projectId: projectId)
        if let order = try? shutdowns.outstanding(projectId: projectId) {
            refreshShutdownProgress(projectId: projectId, order: order)
        }
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
        if now - lastArchiveSweep >= Self.archiveSweepIntervalMillis {
            lastArchiveSweep = now
            sweepArchives(all, now: now)
        }
        for project in all {
            refreshShutdownProgressIfOrdered(projectId: project.id)
            let limits = Self.capLimits(project.settings.caps)
            guard let projectSessions = try? sessions.all(projectId: project.id) else { continue }
            let stallSeconds = project.settings.caps.stallSeconds
            for session in projectSessions where Self.shouldMeter(session, now: now) {
                await meter(session, limits: limits, stallSeconds: stallSeconds)
            }
        }
    }

    /// The tick is what moves a silent worker into `overdue` once its grace period expires. It only
    /// counts: nothing on this path stops a session.
    private func refreshShutdownProgressIfOrdered(projectId: String) {
        guard let order = try? shutdowns.outstanding(projectId: projectId) else {
            shutdownProgress[projectId] = nil
            return
        }
        refreshShutdownProgress(projectId: projectId, order: order)
    }

    /// `manual` and `afterEpicMerge` find nothing here by construction — only `afterDays` has a
    /// deadline that passing time can cross.
    @discardableResult
    func sweepArchives(_ all: [Project], now: Int64 = .nowMillis) -> [String] {
        all.flatMap { (try? archives.run(projectId: $0.id, now: now)) ?? [] }
    }

    private static func shouldMeter(_ session: AgentSession, now: Int64) -> Bool {
        if session.state.isActive { return true }
        guard let endedAt = session.endedAt else { return false }
        return now - endedAt < finalSpendWindowMillis
    }

    private func meter(_ session: AgentSession, limits: CapLimits, stallSeconds: Int) async {
        var totals = UsageTotals(
            inputTokens: session.tokensIn,
            outputTokens: session.tokensOut,
            cacheReadTokens: session.cacheRead,
            cacheWrite5mTokens: session.cacheWrite
        )
        var model = session.model
        var lastActivity = session.lastActivityDate
        // Nil until a transcript has been read: the session row sums what it cost, which says
        // nothing about how full its context is, so there is no fallback to compute this from.
        var context: ContextPressure?

        if let path = session.transcriptPath {
            let url = URL(fileURLWithPath: path)
            if let summary = try? await offMain({ try TranscriptMeter.summarize(transcriptAt: url) }) {
                totals = summary.totals
                context = ContextPressure(
                    usedTokens: summary.contextTokens,
                    limitTokens: ModelCatalog.effectiveContextWindow(for: summary.model ?? model)
                )
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

        guard let current = try? sessions.get(session.sessionId), current.state.isActive else {
            stallNotified.remove(session.sessionId)
            return
        }
        if current.role == .orchestrator, let context {
            consoles[current.projectId]?.contextPressureObserved(context)
        }
        guard current.role == .worker else {
            stallNotified.remove(session.sessionId)
            return
        }
        noteStall(current, lastActivity: lastActivity, stallSeconds: stallSeconds)
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

    /// SPEC §12 case 2: a grandchild process waiting on stdin fires no hook, so a `running` worker whose
    /// activity clock has frozen is only surfaced — never killed. The idle cap still decides that.
    private func noteStall(_ session: AgentSession, lastActivity: Date?, stallSeconds: Int) {
        let stalled = session.state == .running && AttentionSelection.isStalled(
            lastActivity: lastActivity,
            startedAt: session.startedDate,
            now: Date(),
            threshold: TimeInterval(stallSeconds)
        )
        guard stalled else {
            stallNotified.remove(session.sessionId)
            return
        }
        guard stallNotified.insert(session.sessionId).inserted else { return }
        var title: String?
        if let taskId = session.taskId { title = try? tasks.get(taskId)?.title }
        MacNotifier.post(
            title: "Worker may be stuck",
            body: "\(session.displayShortId) has made no tool call in \(stallSeconds)s — \(title ?? "no task"). Attach to check."
        )
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

    static func openingPrompt(
        task: BoardTask, branch: String, attempt: Int, epicGoal: String? = nil, notes: [InjectedNote] = []
    ) -> String {
        OpeningPrompt.compose(task: task, branch: branch, attempt: attempt, epicGoal: epicGoal, notes: notes)
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
