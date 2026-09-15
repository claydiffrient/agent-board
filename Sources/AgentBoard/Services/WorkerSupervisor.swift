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
    case setupInterrupted
    case approvalNotFound(String)
    case epicCloseRefused(String)
    case globalShutdownIncomplete([String])

    var errorDescription: String? {
        switch self {
        case .approvalNotFound(let id): return "approval \(id) not found"
        case .epicCloseRefused(let reason): return reason
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
        case .setupInterrupted:
            return "Agent Board quit while the worktree was still being set up"
        case .globalShutdownIncomplete(let failures):
            return "some projects could not be wound down:\n" + failures.joined(separator: "\n")
        }
    }
}

@MainActor
@Observable
final class WorkerSupervisor: WorkerSupervising, WorkerControl, BoardEventSink {
    private(set) var serverPort: Int?
    private(set) var lastError: String?
    /// The last spawn's worktree path warning, raised by the preflight before that spawn touched
    /// git. Separate from `lastError` so the spawn's own failure cannot overwrite it.
    private(set) var lastWorktreePathWarning: String?
    /// Wind-down progress per project id, refreshed on every delivery, every acknowledgment and
    /// every metering tick, so the progress sheet reads it instead of polling.
    private(set) var shutdownProgress: [String: ShutdownProgress] = [:]

    @ObservationIgnored private let db: AppDatabase
    @ObservationIgnored private let runtime: any AgentRuntime
    @ObservationIgnored private let server: BoardServer
    @ObservationIgnored private let appSupportDir: URL
    @ObservationIgnored private let worktreeBase: URL
    @ObservationIgnored private let projectsRoot: URL
    /// Sampled once per metering tick. Every cap and grace deadline is measured against it so a
    /// suspended machine does not count against a worker.
    @ObservationIgnored private let sleepLedger: SleepLedger
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
    /// Keyed by setup session id, so a test — or a human stopping a worker mid-setup — can wait on
    /// or cancel the half of a spawn that outlives the call.
    @ObservationIgnored private var setupTasks: [String: _Concurrency.Task<Void, Never>] = [:]

    nonisolated static let taskBranchPrefix = TaskStore.branchPrefix
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
        worktreeBase: URL,
        projectsRoot: URL = ClaudeProjectPaths.defaultProjectsRoot,
        sleepLedger: SleepLedger = .shared
    ) {
        self.db = db
        self.runtime = runtime
        self.server = server
        self.appSupportDir = appSupportDir
        self.worktreeBase = worktreeBase
        self.projectsRoot = projectsRoot
        self.sleepLedger = sleepLedger
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
        failInterruptedSetups()
        await migrateWorktreeRoots()
        startMetering()
    }

    /// Idempotent: a project whose root is already space-free is left alone, so the second launch
    /// is a no-op.
    @discardableResult
    func migrateWorktreeRoots() async -> WorktreeRootMigration.Outcome {
        let migration = WorktreeRootMigration(db: db, worktreeBase: worktreeBase)
        let outcome = await _Concurrency.Task.detached(priority: .userInitiated) { migration.run() }.value
        for line in outcome.migrated {
            FileHandle.standardError.write(Data("worktree root migrated: \(line)\n".utf8))
        }
        for line in outcome.skipped + outcome.notices {
            FileHandle.standardError.write(Data("worktree root not migrated: \(line)\n".utf8))
        }
        report(outcome.skipped + outcome.notices)
        return outcome
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
            let worktreeRoot = worktreeBase.appendingPathComponent(id)
            try WorktreeRootRule.validate(worktreeRoot.path)
            let project = Project(
                id: id,
                name: name?.isEmpty == false ? name! : repo.lastPathComponent,
                repoPath: repo.path,
                baseBranch: resolvedBase,
                worktreeRoot: worktreeRoot.path,
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

    /// Answers as soon as the worktree is on disk and the task is claimed; §3.1 steps 3-8 finish in
    /// the background. On a large repository the agent's own start-up outlasts an MCP call, and an
    /// orchestrator that cannot tell a timeout from a failure has to poll to find out what happened.
    @discardableResult
    private func spawn(taskId: String) async throws -> WorkerSpawn {
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
        let warnings = preflightWorktreePath(manager.worktreeRoot.appendingPathComponent(taskId))
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
            let placeholder = try board.assign(
                taskId: taskId,
                session: Self.setupRow(
                    projectId: project.id, taskId: taskId, worktree: worktree, branch: branch, attempt: attempt
                )
            )
            if let epic, epic.state == .planning {
                try epics.setState(epic.id, .active)
            }
            beginSetup(
                LaunchPlan(
                    project: project,
                    taskId: taskId,
                    worktree: worktree,
                    branch: branch,
                    configId: Self.configId(taskId: taskId, attempt: placeholder.attempt),
                    name: Self.sessionName(for: task),
                    prompt: Self.openingPrompt(
                        task: task, branch: branch, attempt: placeholder.attempt, epicGoal: epic?.goal,
                        notes: try notes.notesForSpawn(
                            projectId: project.id, taskId: taskId, epicId: task.epicId
                        ),
                        verification: project.settings.verification
                    ),
                    model: task.model ?? project.settings.defaultModel,
                    attempt: placeholder.attempt
                ),
                placeholder: placeholder,
                port: port
            )
            return WorkerSpawn(
                setupSessionId: placeholder.sessionId, worktreePath: worktree.path, branch: branch,
                warnings: warnings
            )
        } catch {
            throw SupervisorError.spawnFailed(worktree: worktree.path, underlying: describe(error))
        }
    }

    private static func setupRow(
        projectId: String, taskId: String, worktree: URL, branch: String, attempt: Int
    ) -> AgentSession {
        AgentSession(
            sessionId: "setup-\(UUID().uuidString)",
            projectId: projectId,
            taskId: taskId,
            role: .worker,
            worktreePath: worktree.path,
            branch: branch,
            cwd: worktree.path,
            state: .setup,
            attempt: attempt
        )
    }

    /// The failure has nowhere to be thrown once `spawn` has answered, so it reaches the
    /// orchestrator the way every other asynchronous worker outcome does: as a queued report, with
    /// the task put back in `ready` rather than left in `running` behind a session that never ran.
    private func beginSetup(_ plan: LaunchPlan, placeholder: AgentSession, port: Int) {
        let sessionId = placeholder.sessionId
        setupTasks[sessionId] = _Concurrency.Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await launch(plan, port: port, placeholder: placeholder)
            } catch {
                lastError = describe(error)
                // The placeholder may already have been resolved into a real session, in which case
                // that is the row to end — the placeholder no longer exists to be reported against.
                let live = ((try? sessions.forTask(plan.taskId)) ?? [])
                    .first { $0.state.isActive }?.sessionId ?? sessionId
                failSetup(sessionId: live, projectId: plan.project.id, error: error)
            }
            setupTasks[sessionId] = nil
        }
    }

    /// Waits for every spawn whose setup is still running, for callers that need the session that
    /// comes out of it rather than the placeholder `spawn` answered with.
    func waitForSetup() async {
        while let task = setupTasks.values.first {
            await task.value
        }
    }

    private func failSetup(sessionId: String, projectId: String, error: Error) {
        let detail = describe(error)
        let queued = (try? board.terminate(sessionId: sessionId, cause: .setupFailed(detail))) ?? nil
        guard queued != nil else { return }
        announceReports(projectId: projectId)
        MacNotifier.post(title: "Worker never started", body: detail)
    }

    /// A setup that was still running when Agent Board quit has no process behind it any more, and
    /// its task would otherwise sit in `running` forever behind a session that will never start.
    private func failInterruptedSetups() {
        guard let all = try? projects.list() else { return }
        for project in all {
            let stale = ((try? sessions.all(projectId: project.id)) ?? []).filter { $0.state == .setup }
            for session in stale {
                failSetup(
                    sessionId: session.sessionId,
                    projectId: project.id,
                    error: SupervisorError.setupInterrupted
                )
            }
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

    /// §3.1 steps 3-8, shared by task workers and the epic integrator, and the whole of what runs
    /// after `spawn` has answered: memory symlink, generated settings and MCP config, the agent
    /// itself, and the setup row resolved into the session Claude issued.
    private func launch(_ plan: LaunchPlan, port: Int, placeholder: AgentSession) async throws -> AgentSession {
        let project = plan.project
        let memoryDir = URL(fileURLWithPath: project.memoryDir
            ?? ClaudeProjectPaths.memoryDir(forPath: project.repoPath, projectsRoot: projectsRoot).path)
        _ = try ClaudeProjectPaths.linkMemory(worktreePath: plan.worktree.path, to: memoryDir, projectsRoot: projectsRoot)

        let grant = try grants.issue(projectId: project.id, scope: .worker, taskId: plan.taskId)
        do {
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
            let recorded: AgentSession
            do {
                recorded = try sessions.promoteSetupSession(
                    placeholder.sessionId, to: spawned.sessionId, shortId: spawned.shortId
                )
            } catch {
                // Something ended the setup row while the agent was starting, so nothing owns the
                // agent that just came up. Leaving it running would be an untracked worker.
                try? await runtime.stop(shortId: spawned.shortId)
                throw error
            }
            // §3.1 step 8: the grant binds after the session row exists, or the foreign key rejects it.
            try grants.bind(token: grant.token, sessionId: spawned.sessionId)
            try replayEarlyHooks(sessionId: spawned.sessionId)
            return recorded
        } catch {
            try? grants.revoke(token: grant.token)
            throw error
        }
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
        _ = preflightWorktreePath(manager.worktreeRoot.appendingPathComponent(worktreeName))
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
        let dispatched = Set(ordered.filter { ((try? sessions.forTask($0.id)) ?? []).isEmpty == false }.map(\.id))
        let taskIds = ordered.map(\.id)
        let facts = try await offMain { () -> [String: TaskBranchFacts] in
            let merged = try manager.mergeStatus(worktree: worktree, branches: branchNames)
            return try Self.branchFacts(
                manager, taskIds: taskIds, epicBranch: epicBranch, merged: merged, dispatched: dispatched
            )
        }
        let branches = IntegrationPlan.classify(ordered, facts: facts)

        let task = try board.createIntegrationTask(epicId: epicId)
        var assigned: AgentSession?
        do {
            let placeholder = try board.assign(
                taskId: task.id,
                session: Self.setupRow(
                    projectId: project.id, taskId: task.id, worktree: worktree, branch: epicBranch, attempt: 1
                )
            )
            assigned = placeholder
            try epics.setState(epicId, .integrating)
            beginSetup(
                LaunchPlan(
                    project: project,
                    taskId: task.id,
                    worktree: worktree,
                    branch: epicBranch,
                    configId: Self.configId(taskId: task.id, attempt: placeholder.attempt),
                    name: Self.sessionName(for: task),
                    prompt: IntegrationPlan.compose(
                        epic: epic,
                        baseBranch: project.baseBranch,
                        branches: branches,
                        verification: project.settings.verification
                    ),
                    model: project.settings.defaultModel,
                    attempt: placeholder.attempt
                ),
                placeholder: placeholder,
                port: port
            )
            return placeholder
        } catch {
            // A task with a session row on it cannot be deleted; the failure path below owns it.
            if assigned == nil { try? tasks.delete(task.id) }
            throw SupervisorError.spawnFailed(worktree: worktree.path, underlying: describe(error))
        }
    }

    func stop(sessionId: String) async throws {
        try await recording {
            let session = try requireSession(sessionId)
            if let shortId = session.shortId {
                try await runtime.stop(shortId: shortId)
            } else if session.state == .setup {
                // No agent to stop yet; `launch` finds the row gone and stops whatever it started.
                setupTasks[sessionId]?.cancel()
            } else {
                throw SupervisorError.sessionHasNoShortId(sessionId)
            }
            let salvage = await branchSalvage(taskId: session.taskId)
            try board.terminate(sessionId: sessionId, cause: .stoppedByHuman, salvage: salvage)
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
                    if let shortId = session.shortId {
                        try await runtime.stop(shortId: shortId)
                    } else if session.state == .setup {
                        setupTasks[session.sessionId]?.cancel()
                    } else {
                        throw SupervisorError.sessionHasNoShortId(session.sessionId)
                    }
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
            // Its id is Agent Board's own placeholder, so `claude agents` cannot list it and the
            // vanished check below would kill every worker whose repository is still being set up.
            if session.state == .setup { continue }
            guard let info = byId[session.sessionId] else {
                if session.state.isActive {
                    if session.role == .orchestrator, consoles[session.projectId]?.isProcessRunning == true {
                        continue
                    }
                    let salvage = await branchSalvage(taskId: session.taskId)
                    let report = (try? board.terminate(
                        sessionId: session.sessionId, cause: .vanished, salvage: salvage
                    )) ?? nil
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
                    let salvage = await branchSalvage(taskId: session.taskId)
                    let report = (try? board.terminate(
                        sessionId: session.sessionId, cause: .vanished, salvage: salvage
                    )) ?? nil
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
        await recoverStrandedTasks(projectId: projectId)
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

    /// A task branch that git no longer has is read from the ledger, never from its own absence:
    /// Agent Board deletes a task branch precisely because its work was merged.
    nonisolated static func branchFacts(
        _ manager: WorktreeManager,
        taskIds: [String],
        epicBranch: String,
        merged: [String: Bool],
        dispatched: Set<String>
    ) throws -> [String: TaskBranchFacts] {
        let epicRef = "refs/heads/\(epicBranch)"
        var facts: [String: TaskBranchFacts] = [:]
        for taskId in taskIds {
            let branch = IntegrationPlan.branchName(taskId: taskId)
            var fact = TaskBranchFacts(
                branchExists: try manager.branchExists(branch),
                mergedIntoEpic: merged[branch] == true,
                everDispatched: dispatched.contains(taskId)
            )
            if !fact.branchExists {
                fact.recordedBase = try manager.refCommit(TaskBranchLedger.baseRef(taskId: taskId))
                fact.recordedTip = try manager.refCommit(TaskBranchLedger.tipRef(taskId: taskId))
                if let tip = fact.recordedTip {
                    fact.tipOnEpicBranch = try manager.isMerged(commit: tip, into: epicRef)
                    if let base = fact.recordedBase {
                        fact.ownCommits = try manager.commitCount(from: base, to: tip)
                    }
                }
            }
            facts[taskId] = fact
        }
        return facts
    }

    /// A session death that never reached `terminate` — the row already inactive when the cap or
    /// `reconcile` got there, or no row at all — leaves its task in `running`, where `spawn_worker`
    /// refuses it and no report is ever coming. Nothing else clears that, so both the metering tick
    /// and `reconcile` sweep it: `reconcile` only runs while the Status screen is on screen, and a
    /// task must not stay unreachable for as long as nobody happens to look at it.
    func recoverStrandedTasks(projectId: String) async {
        guard let stranded = try? board.strandedRunningTasks(projectId: projectId), !stranded.isEmpty else { return }
        var queued = false
        for task in stranded {
            let salvage = await branchSalvage(taskId: task.id)
            let report = (try? board.recoverStranded(taskId: task.id, salvage: salvage)) ?? nil
            queued = queued || report != nil
        }
        if queued { announceReports(projectId: projectId) }
    }

    /// What git can say about a task's branch, for a failure report to carry rather than throw the
    /// work back to `ready` as if the branch were empty. Best effort: nil claims nothing.
    private func branchSalvage(taskId: String?) async -> BranchSalvage? {
        guard let taskId, let task = try? tasks.get(taskId),
              let project = try? projects.get(task.projectId)
        else { return nil }
        let manager = Self.worktreeManager(for: project)
        let branch = Self.taskBranchPrefix + taskId
        let fallbackBase = mergeTargets(for: task, project: project).last ?? project.baseBranch
        let worktree = (try? sessions.forTask(taskId).compactMap(\.worktreePath))?
            .first { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
        return try? await offMain {
            try Self.readSalvage(manager: manager, branch: branch, fallbackBase: fallbackBase, worktree: worktree)
        }
    }

    /// The branch was cut from the ledger's recorded base; `fallbackBase` only covers a branch that
    /// predates the ledger. A base that no longer resolves makes the count a lie, so nothing is claimed.
    private nonisolated static func readSalvage(
        manager: WorktreeManager, branch: String, fallbackBase: String, worktree: URL?
    ) throws -> BranchSalvage? {
        guard try manager.branchExists(branch) else { return nil }
        let recorded = TaskBranchLedger.taskId(ofBranch: branch)
            .flatMap { try? manager.refCommit(TaskBranchLedger.baseRef(taskId: $0)) }
        let base = recorded ?? fallbackBase
        guard try manager.commitExists(base) else { return nil }
        let dirty = worktree.map { (try? manager.hasUncommittedChanges(worktree: $0)) ?? false } ?? false
        return BranchSalvage(
            branch: branch,
            commitsAheadOfBase: try manager.commitCount(from: base, to: "refs/heads/\(branch)"),
            uncommittedChanges: dirty
        )
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

    /// Runs before the first git command of a spawn: `git worktree add` fires the repository's
    /// `post-checkout` hook, so by the time the path is on disk its setup has already run in it.
    @discardableResult
    private func preflightWorktreePath(_ path: URL) -> [String] {
        let warning = WorktreePathDiagnosis.preflight(worktreePath: path.path)?.message
        lastWorktreePathWarning = warning
        guard let warning else { return [] }
        FileHandle.standardError.write(Data("worktree path warning: \(warning)\n".utf8))
        report([warning])
        return [warning]
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
            case .push, .pullRequest:
                try await publish(approval)
            }
        }
    }

    /// The human's half of D8's orchestrator path: the orchestrator asked, this grant is what lets
    /// anything reach the remote. Whatever happens is written back to the board — the pull request
    /// URL on the card, and a `decision` report the orchestrator pulls — including the failure,
    /// which names its own cause (no remote, no `gh`, not logged in).
    private func publish(_ approval: Approval) async throws {
        guard let project = try projects.get(approval.projectId) else {
            throw SupervisorError.projectNotFound(approval.projectId)
        }
        let request = try approval.publishRequest()
        let publisher = BranchPublisher(repoPath: URL(fileURLWithPath: project.repoPath))
        let base = request.base ?? project.baseBranch
        do {
            switch approval.kind {
            case .push:
                let result = try await offMain { try publisher.push(branch: request.branch, remote: request.remote) }
                try board.recordPublished(approval: approval, summary: "Push approved: \(result.summary).")
            case .pullRequest:
                let result = try await offMain {
                    try publisher.openPullRequest(
                        branch: request.branch, base: base, title: request.title ?? request.branch,
                        body: request.body ?? "", remote: request.remote
                    )
                }
                let verb = result.alreadyOpen ? "Pull request already open" : "Pull request opened"
                try board.recordPublished(
                    approval: approval,
                    summary: "\(verb) from \(request.branch) into \(base).",
                    url: result.url
                )
            case .spawn, .integration:
                return
            }
        } catch {
            try? board.recordPublished(
                approval: approval,
                summary: "\(approval.kind.rawValue) failed for \(request.branch): \(describe(error))",
                failed: true
            )
            announceReports(projectId: approval.projectId)
            throw error
        }
        announceReports(projectId: approval.projectId)
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

    /// SPEC §10: the preflight behind the close/abandon confirmation.
    func epicClosurePlan(epicId: String, as closure: EpicClosure) throws -> EpicClosurePlan {
        try board.epicClosurePlan(epicId: epicId, as: closure)
    }

    /// SPEC §10: a human ends the epic without integrating it. Board state and a `decision` report,
    /// nothing else — no merge, no push, no worktree teardown, no task touched.
    func closeEpic(epicId: String, as closure: EpicClosure) async throws {
        try await recording {
            let plan = try board.epicClosurePlan(epicId: epicId, as: closure)
            if plan.isRefused { throw SupervisorError.epicCloseRefused(plan.message) }
            let report = try board.closeEpic(epicId: epicId, as: closure, by: "human")
            announceReports(projectId: report.projectId)
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
            let workers = try sessions.active(projectId: projectId)
                .filter { $0.role == .worker && $0.state != .setup }
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
        let progress = (try? deliveries.progress(orderId: order.id, graceSeconds: grace, awake: sleepLedger.reading()))
            ?? ShutdownProgress(orderId: order.id, total: 0, acknowledged: 0)
        shutdownProgress[projectId] = progress
        return progress
    }

    /// Raises an order on every project, then delivers them all. The two passes are deliberate:
    /// delivering project by project would leave the projects further down the list unordered
    /// while the first ones' resumes are in flight, and an orchestrator could spawn into that gap.
    /// A project with no active worker still gets its order for the same reason.
    @discardableResult
    func requestGlobalShutdown(requestedBy: String = "human", reason: String? = nil) async throws -> [ShutdownOrder] {
        let all = try projects.list()
        var raised: [ShutdownOrder] = []
        var failures: [String] = []
        for project in all {
            do {
                raised.append(try await requestShutdown(projectId: project.id, requestedBy: requestedBy, reason: reason))
            } catch {
                failures.append("\(project.name): \(describe(error))")
            }
        }
        for project in all where raised.contains(where: { $0.projectId == project.id }) {
            do {
                _ = try await deliverShutdownOrder(projectId: project.id)
            } catch {
                failures.append("\(project.name): \(describe(error))")
            }
        }
        if !failures.isEmpty { throw SupervisorError.globalShutdownIncomplete(failures) }
        return raised
    }

    /// Every project is attempted before anything is thrown. A partial cancel is the one outcome
    /// this must not produce: a project left refusing spawns with no sheet on screen saying why.
    @discardableResult
    func cancelGlobalShutdown(by: String = "human") async throws -> [ShutdownOrder] {
        let all = try projects.list()
        var lifted: [ShutdownOrder] = []
        var failures: [String] = []
        for project in all {
            do {
                if let order = try await cancelShutdown(projectId: project.id, by: by) { lifted.append(order) }
            } catch {
                failures.append("\(project.name): \(describe(error))")
            }
        }
        if !failures.isEmpty { throw SupervisorError.globalShutdownIncomplete(failures) }
        return lifted
    }

    /// The consoles are PTYs this process owns, so they die with it either way. Stopping them
    /// first makes the exit deliberate: each session is marked `stopped` rather than left looking
    /// active in a database the next launch reads.
    func stopOrchestratorConsoles() {
        for console in consoles.values { console.stop() }
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

    func spawnWorker(taskId: String) async throws -> WorkerSpawn {
        try await recording { try await spawn(taskId: taskId) }
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

    /// Internal so a test can drive one tick without waiting out the timer.
    func meterTick() async {
        guard let all = try? projects.list() else { return }
        let awake = sleepLedger.reading()
        let now = awake.nowMillis
        if now - lastArchiveSweep >= Self.archiveSweepIntervalMillis {
            lastArchiveSweep = now
            sweepArchives(all, now: now)
        }
        for project in all {
            refreshShutdownProgressIfOrdered(projectId: project.id)
            await recoverStrandedTasks(projectId: project.id)
            let limits = Self.capLimits(project.settings.caps)
            guard let projectSessions = try? sessions.all(projectId: project.id) else { continue }
            let stallSeconds = project.settings.caps.stallSeconds
            for session in projectSessions where Self.shouldMeter(session, now: now) {
                await meter(session, limits: limits, stallSeconds: stallSeconds, awake: awake)
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

    private func meter(_ session: AgentSession, limits: CapLimits, stallSeconds: Int, awake: AwakeElapsed) async {
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
        noteStall(current, lastActivity: lastActivity, stallSeconds: stallSeconds, awake: awake)
        guard let breach = CapEvaluator.evaluate(
            totals: totals,
            startedAt: current.startedDate,
            lastActivity: lastActivity,
            awake: awake,
            limits: limits
        ) else { return }
        if case .idle = breach, current.state == .blocked || current.state == .setup { return }
        await enforce(breach, on: current, awake: awake)
    }

    /// SPEC §12 case 2: a grandchild process waiting on stdin fires no hook, so a `running` worker whose
    /// activity clock has frozen is only surfaced — never killed. The idle cap still decides that.
    private func noteStall(_ session: AgentSession, lastActivity: Date?, stallSeconds: Int, awake: AwakeElapsed) {
        let stalled = session.state == .running && AttentionSelection.isStalled(
            lastActivity: lastActivity,
            startedAt: session.startedDate,
            awake: awake,
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

    private func enforce(_ breach: CapBreach, on session: AgentSession, awake: AwakeElapsed) async {
        let description = Self.describe(breach, awake: awake)
        if let shortId = session.shortId {
            try? await runtime.stop(shortId: shortId)
        }
        let salvage = await branchSalvage(taskId: session.taskId)
        _ = try? board.terminate(sessionId: session.sessionId, cause: .capBreach(description), salvage: salvage)
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

    private static func describe(_ breach: CapBreach, awake: AwakeElapsed) -> String {
        switch breach {
        case .tokens(let used, let limit):
            return "token cap reached: \(used) of \(limit) tokens"
        case .wallClock(let elapsed, let limit):
            return "elapsed cap reached: \(Int(elapsed / 60)) of \(Int(limit / 60)) awake minutes"
        case .idle(let since, let limit):
            let idleFor = Int(awake.secondsAwake(since: since) / 60)
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
        task: BoardTask,
        branch: String,
        attempt: Int,
        epicGoal: String? = nil,
        notes: [InjectedNote] = [],
        verification: VerificationCommands = VerificationCommands()
    ) -> String {
        OpeningPrompt.compose(
            task: task, branch: branch, attempt: attempt, epicGoal: epicGoal, notes: notes,
            verification: verification
        )
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
