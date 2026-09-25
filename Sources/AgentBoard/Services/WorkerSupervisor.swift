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
    case taskAlreadyHeld(title: String, sessionId: String)
    case worktreeAlreadyHeld(path: String, sessionId: String)
    case shutdownOrdered
    case noShutdownOrder
    case serverNotRunning
    case spawnFailed(worktree: String, underlying: String)
    case setupInterrupted
    case approvalNotFound(String)
    case rosterAgentNotUsable(id: String, projectName: String)
    case epicCloseRefused(String)
    case globalShutdownIncomplete([String])

    var errorDescription: String? {
        switch self {
        case .approvalNotFound(let id): return "approval \(id) not found"
        case .rosterAgentNotUsable(let id, let projectName):
            return "roster agent \(id) is not in \(projectName)'s usable set; enable it for this project first"
        case .epicCloseRefused(let reason): return reason
        case .epicNotFound(let id): return "epic \(id) not found"
        case .notAGitRepository(let path): return "\(path) is not a git repository"
        case .projectNotFound(let id): return "project \(id) not found"
        case .taskNotFound(let id): return "task \(id) not found"
        case .sessionNotFound(let id): return "session \(id) not found"
        case .sessionHasNoShortId(let id): return "session \(id) has no claude short id yet; reconcile first"
        case .taskNotAssignable(let title, let column): return "\"\(title)\" is in \(column.rawValue) and cannot be assigned"
        case .capRefused(let reason): return "spawn refused: \(reason)"
        case .taskAlreadyHeld(let title, let sessionId):
            return "\"\(title)\" is still held by session \(sessionId); a second agent would share its worktree"
        case .worktreeAlreadyHeld(let path, let sessionId):
            return "session \(sessionId) is still working in \(path); a second agent must not share it"
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
    /// Nil in tests that do not care; the app always supplies one. SPEC §8.3.
    @ObservationIgnored private let sleepGuard: SleepGuard?
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
    @ObservationIgnored private let roster: RosterStore
    @ObservationIgnored private let board: Board
    @ObservationIgnored private let archives: ArchiveSweep
    @ObservationIgnored private let fileLocks: FileLockStore
    @ObservationIgnored private let attention: ProjectAttentionStore
    @ObservationIgnored private let pullRequestStates: PullRequestStateReader
    /// Millis of the last pull request merge check; 0 means none yet, so the first tick after
    /// launch checks.
    @ObservationIgnored private var lastPullRequestCheck: Int64 = 0
    /// Tasks whose pull request is being checked, so overlapping checks cannot both report a close.
    @ObservationIgnored private var landingChecksInFlight: Set<String> = []
    @ObservationIgnored private let mergeQueue = BranchMergeQueue()
    /// Which project needs a human and which of those has already been announced. Polled on the
    /// metering tick rather than observed, because `overdueShutdown` and any future deadline cause
    /// only become true as the clock moves, and a `ValueObservation` re-fires on writes alone.
    @ObservationIgnored private var attentionNotifier = AttentionNotifier()
    /// The project whose screen is open, pushed by `MainWindow`. Nil when the window is on At a
    /// Glance; combined with `NSApp.isActive` it decides which banners are redundant.
    @ObservationIgnored private var focusedProject: String?
    @ObservationIgnored private var meteringTask: _Concurrency.Task<Void, Never>?
    /// Millis of the last archive sweep; 0 means none yet, so the first tick after launch sweeps
    /// and picks up whatever came due while the app was closed.
    @ObservationIgnored private var lastArchiveSweep: Int64 = 0
    /// Sessions already announced as stalled, so the tick notifies on the transition, not every 5s.
    @ObservationIgnored private var stallNotified: Set<String> = []
    /// `<project-id>\u{01}<branch>` for each shared branch whose pre-ledger `Agent-Board-Task`
    /// trailers have already been read back this run.
    @ObservationIgnored private var trailersBackfilled: Set<String> = []
    @ObservationIgnored private var consoles: [String: OrchestratorConsole] = [:]
    @ObservationIgnored private var shellConsoles: [String: ShellConsole] = [:]
    /// Keyed by setup session id, so a test — or a human stopping a worker mid-setup — can wait on
    /// or cancel the half of a spawn that outlives the call.
    @ObservationIgnored private var setupTasks: [String: _Concurrency.Task<Void, Never>] = [:]

    nonisolated static let taskBranchPrefix = TaskStore.branchPrefix
    static let meteringInterval: Duration = .seconds(5)
    /// The archive policies are day-granular, so they ride the metering tick at a far coarser
    /// cadence rather than paying for a scan every 5 seconds — or a second timer.
    static let archiveSweepIntervalMillis: Int64 = 5 * 60 * 1000
    static let pullRequestCheckIntervalMillis: Int64 = 10 * 60 * 1000
    /// Sessions that ended this recently still get one more transcript read so final spend lands.
    static let finalSpendWindowMillis: Int64 = 15_000

    init(
        db: AppDatabase,
        runtime: any AgentRuntime,
        server: BoardServer,
        appSupportDir: URL,
        worktreeBase: URL,
        projectsRoot: URL = ClaudeProjectPaths.defaultProjectsRoot,
        sleepLedger: SleepLedger = .shared,
        sleepGuard: SleepGuard? = nil,
        gh: any GhRunning = SystemGh()
    ) {
        self.db = db
        self.runtime = runtime
        self.server = server
        self.appSupportDir = appSupportDir
        self.worktreeBase = worktreeBase
        self.projectsRoot = projectsRoot
        self.sleepLedger = sleepLedger
        self.sleepGuard = sleepGuard
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
        roster = RosterStore(db)
        board = Board(db)
        archives = ArchiveSweep(db)
        fileLocks = FileLockStore(db)
        attention = ProjectAttentionStore(db)
        pullRequestStates = PullRequestStateReader(gh: gh)
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
        sweepStaleFileLocks()
        await sweepLeakedAgents()
        await migrateWorktreeRoots()
        refreshSleepAssertion()
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
    private func spawn(
        taskId: String, rosterAgentId: String? = nil, scope: AgentBoardCore.TokenScope = .worker
    ) async throws -> WorkerSpawn {
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
        let agent = try rosterAgentId.map { id -> RosterAgent in
            guard let agent = try roster.usableAgent(id, forProject: project.id) else {
                throw SupervisorError.rosterAgentNotUsable(id: id, projectName: project.name)
            }
            return agent
        }
        // A handed-off task is back in `ready` while its worktree stays on disk, so the column alone no
        // longer proves nobody is in it. `Board.assign` re-checks this in its transaction; refusing here
        // as well keeps a doomed spawn from launching a process it would then have to orphan.
        if let holder = try sessions.activeHolder(taskId: taskId) {
            throw SupervisorError.taskAlreadyHeld(title: task.title, sessionId: holder.sessionId)
        }

        let attempt = try sessions.forTask(taskId).count + 1
        let manager = worktreeManager(for: project)
        let epic = try task.epicId.flatMap { try epics.get($0) }
        // A reviewer reads the worker's own worktree. A task worked in the shared checkout never
        // reaches agent review (SPEC §5.1), so the strategy has no say here.
        let placement = scope == .reviewer ? WorkerPlacement.worktree : WorkerPlacementDecision.decide(
            strategy: project.settings.worktreeStrategy,
            wantedSharedBranch: SharedCheckoutGroup.branch(epicId: task.epicId),
            group: try SharedCheckoutGroup.current(db: db, projectId: project.id)
        )
        // Before the first git command either way: `git worktree add` fires the repository's
        // post-checkout hook, so a path that hook cannot survive has to be named while nothing has
        // run yet. A shared placement creates no path, so it has nothing to judge and says nothing.
        let warnings = placement == .worktree
            ? preflightWorktreePath(manager.worktreeRoot.appendingPathComponent(taskId))
            : clearedWorktreePathWarning()
        let base: String
        if let epic {
            let epicBranch = epic.branch
            let projectBase = project.baseBranch
            try await offMain { try manager.ensureBranch(epicBranch, from: projectBase) }
            base = epicBranch
        } else {
            base = project.baseBranch
        }
        let site = try await checkoutSite(
            project: project, taskId: taskId, placement: placement, base: base, manager: manager,
            warnings: warnings
        )
        let branch = site.branch
        // A handed-off task keeps its worktree on disk, so a second agent could otherwise be launched
        // into a checkout someone is still working in. Co-resident agents in a shared checkout are
        // deliberate and have no worktree path, so this skips them.
        if let path = site.worktreePath, let holder = try sessions.activeHolder(worktreePath: path) {
            throw SupervisorError.worktreeAlreadyHeld(path: path, sessionId: holder.sessionId)
        }

        do {
            let reviewHead = scope == .reviewer
                ? try await offMain { try ReviewCheckout.baseline(in: site.cwd) }
                : nil
            let row = Self.setupRow(
                projectId: project.id, taskId: taskId, site: site, attempt: attempt,
                rosterAgentId: agent?.id, reviewHead: reviewHead
            )
            // A reviewer holds a task that is already in `review`; `assign` would move it to
            // `running` and take it out of the queue its own accept_task reads.
            let placeholder = scope == .reviewer
                ? try board.assignReviewer(taskId: taskId, session: row)
                : try board.assign(taskId: taskId, session: row)
            if let epic, epic.state == .planning {
                try epics.setState(epic.id, .active)
            }
            beginSetup(
                LaunchPlan(
                    project: project,
                    taskId: taskId,
                    cwd: site.cwd,
                    worktreePath: site.worktreePath,
                    branch: branch,
                    configId: Self.configId(taskId: taskId, attempt: placeholder.attempt),
                    name: Self.sessionName(for: task),
                    prompt: scope == .reviewer
                        ? ReviewPrompt.compose(
                            task: task, branch: branch, base: base,
                            verification: project.settings.verification,
                            workingDirectory: site.cwd.path,
                            agent: agent?.identity,
                            comments: try CommentStore(db).list(taskId: taskId)
                        )
                        : Self.openingPrompt(
                            task: task, branch: branch, attempt: placeholder.attempt, epicGoal: epic?.goal,
                            notes: try notes.notesForSpawn(
                                projectId: project.id, taskId: taskId, epicId: task.epicId
                            ),
                            verification: project.settings.verification,
                            placement: site.placement,
                            workingDirectory: site.cwd.path,
                            agent: agent?.identity,
                            reviewFindings: try ProgressStore(db).openReviewFindings(taskId: taskId),
                            comments: try CommentStore(db).list(taskId: taskId)
                        ),
                    // Most specific override wins: this task, then the agent's standing preference,
                    // then the project default.
                    model: task.model ?? agent?.model ?? project.settings.defaultModel,
                    attempt: placeholder.attempt,
                    rosterAgent: agent,
                    scope: scope
                ),
                placeholder: placeholder,
                port: port
            )
            return WorkerSpawn(
                setupSessionId: placeholder.sessionId, worktreePath: site.cwd.path, branch: branch,
                sharesCheckout: site.placement.sharedBranch != nil, warnings: site.warnings
            )
        } catch {
            throw SupervisorError.spawnFailed(worktree: site.cwd.path, underlying: describe(error))
        }
    }

    /// SPEC §5.1: the reviewer's checkout must be as `spawn` recorded it. A session with no recorded
    /// baseline cannot be vouched for, so its verdict is refused too.
    func reviewCheckoutChange(taskId: String, sessionId: String?) async throws -> String? {
        let session = try sessionId.flatMap { try sessions.get($0) }
            ?? sessions.forTask(taskId).first { $0.reviewHead != nil && $0.state.isActive }
        guard let session, session.taskId == taskId, let head = session.reviewHead else {
            return "Agent Board has no record of the HEAD this review started from."
        }
        let cwd = URL(fileURLWithPath: session.cwd)
        return try await offMain { try ReviewCheckout.change(since: head, in: cwd) }
    }

    /// Where a worker will run, once the strategy, the group holding the checkout and git have all
    /// had their say.
    private struct CheckoutSite {
        var placement: WorkerPlacement
        var cwd: URL
        /// Nil for a shared checkout: there is no worktree to record, move, diff or tear down.
        var worktreePath: String?
        var branch: String
        var warnings: [String]
    }

    /// Carries out the placement. A `shared` one that git will not accept — a dirty checkout, or a
    /// branch another worktree holds — degrades to a worktree with a notice rather than failing the
    /// spawn.
    private func checkoutSite(
        project: Project, taskId: String, placement: WorkerPlacement, base: String,
        manager: WorktreeManager, warnings: [String]
    ) async throws -> CheckoutSite {
        if let sharedBranch = placement.sharedBranch {
            let repo = URL(fileURLWithPath: project.repoPath)
            do {
                try await offMain { try manager.adoptSharedBranch(sharedBranch, from: base) }
                return CheckoutSite(
                    placement: placement, cwd: repo, worktreePath: nil, branch: sharedBranch, warnings: warnings
                )
            } catch {
                report(["\(project.name): the shared checkout could not be used, so this task got a worktree. \(describe(error))"])
            }
        }
        let branch = Self.taskBranchPrefix + taskId
        let fallbackWarnings = placement == .worktree
            ? warnings
            : preflightWorktreePath(manager.worktreeRoot.appendingPathComponent(taskId))
        let worktree = try await offMain {
            try Self.existingWorktree(manager, name: taskId) ?? manager.create(name: taskId, branch: branch, base: base)
        }
        return CheckoutSite(
            placement: .worktree, cwd: worktree, worktreePath: worktree.path, branch: branch,
            warnings: fallbackWarnings
        )
    }

    /// A shared placement creates no path, so a warning left over from an earlier spawn would be
    /// read as this one's.
    private func clearedWorktreePathWarning() -> [String] {
        lastWorktreePathWarning = nil
        return []
    }

    private static func setupRow(
        projectId: String, taskId: String, site: CheckoutSite, attempt: Int,
        rosterAgentId: String? = nil, reviewHead: String? = nil
    ) -> AgentSession {
        AgentSession(
            sessionId: "setup-\(UUID().uuidString)",
            projectId: projectId,
            taskId: taskId,
            role: .worker,
            worktreePath: site.worktreePath,
            branch: site.branch,
            cwd: site.cwd.path,
            state: .setup,
            attempt: attempt,
            rosterAgentId: rosterAgentId,
            reviewHead: reviewHead
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
        // `sessionId` always names a real row (`assign` writes it before setup runs), so this could
        // route to `.session(sessionId)` the way the stall and cap banners do. It stays on `.project`
        // because the Status row it would land on carries no diagnosis — no transcript, no spend, a
        // bare `failed` state — while `detail` is the actual worktree-prep failure, which only the
        // queued report on the Orchestrator screen shows.
        post("Worker never started", body: detail, projectId: projectId, category: .workerFailures)
    }

    /// A lock held by a session the last run of the app never saw end — a killed process, a crash —
    /// would keep a file in the shared checkout claimed by nobody. Same shape as
    /// `failInterruptedSetups`: sweep it at launch, before any worker can contend for it.
    @discardableResult
    func sweepStaleFileLocks() -> [FileLock] {
        let swept = (try? fileLocks.sweepStale()) ?? []
        for lock in swept {
            FileHandle.standardError.write(
                Data("stale file lock released: \(lock.path) (session \(lock.sessionId))\n".utf8)
            )
        }
        return swept
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
        var cwd: URL
        /// Nil when the worker runs in the project's own checkout.
        var worktreePath: String?
        var branch: String
        var configId: String
        var name: String
        var prompt: String
        var model: String?
        var attempt: Int
        /// A rostered assignment. Nothing here widens authority: the session still gets
        /// `--permission-mode auto`, the worker deny list, and at most a worker's token scope.
        var rosterAgent: RosterAgent? = nil
        var scope: AgentBoardCore.TokenScope = .worker
    }

    /// §3.1 steps 3-8, shared by task workers and the epic integrator, and the whole of what runs
    /// after `spawn` has answered: memory symlink, generated settings and MCP config, the agent
    /// itself, and the setup row resolved into the session Claude issued.
    private func launch(_ plan: LaunchPlan, port: Int, placeholder: AgentSession) async throws -> AgentSession {
        let project = plan.project
        let memoryDir = URL(fileURLWithPath: project.memoryDir
            ?? ClaudeProjectPaths.memoryDir(forPath: project.repoPath, projectsRoot: projectsRoot).path)
        _ = try ClaudeProjectPaths.linkMemory(worktreePath: plan.cwd.path, to: memoryDir, projectsRoot: projectsRoot)

        let grant = try grants.issue(projectId: project.id, scope: plan.scope, taskId: plan.taskId)
        do {
            let configFiles = try SessionConfigWriter.write(
                configDir: sessionConfigDir,
                configId: plan.configId,
                port: port,
                token: grant.token,
                autoModeJSON: project.settings.autoModeJSON,
                extraMcpServers: nil,
                fileLocks: plan.worktreePath == nil
            )
            let request = SpawnRequest(
                cwd: plan.cwd,
                name: plan.name,
                prompt: plan.prompt,
                configFiles: configFiles,
                // A deny-list, layered on: a rostered agent can only ever have less authority than a
                // plain worker, and an empty list is exactly a plain worker's.
                disallowedTools: SpawnRequest.defaultDisallowedTools
                    + (plan.scope == .reviewer ? SpawnRequest.reviewerDisallowedTools : [])
                    + (plan.rosterAgent?.disallowedTools ?? []),
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

        let manager = worktreeManager(for: project)
        let worktreeName = "epic-\(epicId)"
        _ = preflightWorktreePath(manager.worktreeRoot.appendingPathComponent(worktreeName))
        let epicBranch = epic.branch
        let worktree = try await offMain {
            try Self.existingWorktree(manager, name: worktreeName)
                ?? manager.createForBranch(name: worktreeName, branch: epicBranch)
        }
        if let holder = try sessions.activeHolder(worktreePath: worktree.path) {
            throw SupervisorError.worktreeAlreadyHeld(path: worktree.path, sessionId: holder.sessionId)
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
        let shared = ordered.reduce(into: [String: String]()) { map, member in
            map[member.id] = sharedBranch(of: member)
        }
        let projectBase = project.baseBranch
        let facts = try await offMain { () -> [String: TaskBranchFacts] in
            let merged = try manager.mergeStatus(worktree: worktree, branches: branchNames)
            return try Self.branchFacts(
                manager, taskIds: taskIds, epicBranch: epicBranch, baseBranch: projectBase,
                sharedBranches: shared, merged: merged, dispatched: dispatched
            )
        }
        let branches = IntegrationPlan.classify(ordered, facts: facts)

        let task = try board.createIntegrationTask(epicId: epicId)
        var assigned: AgentSession?
        do {
            let placeholder = try board.assign(
                taskId: task.id,
                session: Self.setupRow(
                    projectId: project.id,
                    taskId: task.id,
                    site: CheckoutSite(
                        placement: .worktree, cwd: worktree, worktreePath: worktree.path,
                        branch: epicBranch, warnings: []
                    ),
                    attempt: 1
                )
            )
            assigned = placeholder
            // A PR-open epic stays so: its pull request, not this integrator, decides when it is done.
            if epic.state != .pullRequestOpen { try epics.setState(epicId, .integrating) }
            beginSetup(
                LaunchPlan(
                    project: project,
                    taskId: task.id,
                    cwd: worktree,
                    worktreePath: worktree.path,
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
        try await recording { try await stopSession(sessionId, by: .human) }
    }

    private func stopSession(_ sessionId: String, by actor: BoardActor) async throws {
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
        try board.terminate(sessionId: sessionId, cause: .stopped(by: actor), salvage: salvage)
        try grants.revokeAll(sessionId: sessionId)
        announceReports(projectId: session.projectId)
        refreshSleepAssertion()
    }

    func resume(sessionId: String) async throws {
        try await recording {
            let session = try requireSession(sessionId)
            let placement = try projects.get(session.projectId).map {
                WorkerStanding.recorded(session: session, project: $0, taskId: session.taskId ?? "").placement
            } ?? .worktree
            try await resume(
                session,
                prompt: Self.resumePrompt(previousStop: session.stopReason, placement: placement)
            )
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
                    try board.terminate(sessionId: session.sessionId, cause: .stopped(by: .human))
                } catch {
                    firstFailure = firstFailure ?? error
                }
            }
            announceReports(projectId: projectId)
            refreshSleepAssertion()
            if let firstFailure { throw firstFailure }
        }
    }

    func accept(taskId: String) async throws {
        try await accept(taskId: taskId, acceptedBy: .human)
    }

    func accept(taskId: String, acceptedBy: TaskAcceptance) async throws {
        try await recording {
            guard let task = try tasks.get(taskId) else { throw SupervisorError.taskNotFound(taskId) }
            guard let project = try projects.get(task.projectId) else {
                throw SupervisorError.projectNotFound(task.projectId)
            }
            try await stopLiveSessions(onTask: taskId, sparing: acceptedBy.acceptingSessionId, by: acceptedBy.actor)
            try board.accept(taskId: taskId, acceptedBy: acceptedBy)
            let taskSessions = try sessions.forTask(taskId)
            for session in taskSessions {
                try grants.revokeAll(sessionId: session.sessionId)
                try fileLocks.releaseAll(sessionId: session.sessionId)
            }
            // Teardown runs first so `deleteBranchIfMerged` still sees the task branch as unmerged
            // and keeps it; the integrator reads the surviving branch as its ledger of what is in.
            await tearDownWorktrees(of: taskSessions, task: task, project: project)
            await landAcceptedBranch(task: task, project: project)
            announceReports(projectId: task.projectId)
        }
    }

    /// SPEC §5: a rostered reviewer runs in the worker's own worktree, so a decision taken over its
    /// head must end it before anything removes that checkout. Only an agent `claude agents` still
    /// lists as live can abort the decision; a row whose process is gone is ended as vanished.
    private func stopLiveSessions(onTask taskId: String, sparing: String? = nil, by actor: BoardActor) async throws {
        var listing: [AgentInfo]?
        for session in try sessions.forTask(taskId) where session.state.isActive && session.sessionId != sparing {
            do {
                try await stopSession(session.sessionId, by: actor)
            } catch {
                if listing == nil {
                    guard let listed = try? await runtime.listSessions() else { throw error }
                    listing = listed
                }
                guard let info = Self.liveListing(of: session, in: listing ?? []) else {
                    let salvage = await branchSalvage(taskId: session.taskId)
                    try board.terminate(sessionId: session.sessionId, cause: .vanished, salvage: salvage)
                    try grants.revokeAll(sessionId: session.sessionId)
                    announceReports(projectId: session.projectId)
                    refreshSleepAssertion()
                    continue
                }
                guard session.shortId == nil, let shortId = info.id else { throw error }
                try sessions.setShortId(session.sessionId, shortId)
                try await stopSession(session.sessionId, by: actor)
            }
        }
    }

    private static func liveListing(of session: AgentSession, in listing: [AgentInfo]) -> AgentInfo? {
        listing.first { info in
            let named = info.sessionId == session.sessionId || (session.shortId != nil && info.id == session.shortId)
            return named && info.state?.lowercased() != "stopped" && info.status?.lowercased() != "stopped"
        }
    }

    /// §5: an accepted task's branch is merged into the branch meant to carry it — the epic branch
    /// for a task in an epic, the project's base branch otherwise, unless the project integrates
    /// standalone tasks by pull request, which merges nothing — and, whatever happens, the
    /// task's `landing` records where the work ended up. Deliberately outside the acceptance
    /// transaction: the human accepted the task, and no git failure may put it back. What a git
    /// failure does instead is leave `landing` at `.unlanded`, which the board shows, so `done`
    /// cannot quietly mean "done, and the work is nowhere".
    private func landAcceptedBranch(task: BoardTask, project: Project) async {
        let epic = task.epicId.flatMap { try? epics.get($0) }
        // A shared branch holds several tasks' commits on one ref, so it lands as a unit when its
        // last member is accepted (§8.4) rather than once per task.
        if let epic, let shared = sharedBranch(of: task) {
            await mergeQueue.serialize(repo: project.repoPath, branch: epic.branch) {
                await mergeSharedBranch(task: task, epic: epic, project: project, branch: shared)
            }
            return
        }
        let target = epic?.branch ?? project.baseBranch
        await mergeQueue.serialize(repo: project.repoPath, branch: target) {
            await mergeTaskBranch(task: task, epic: epic, project: project, into: target)
        }
    }

    private func mergeTaskBranch(task: BoardTask, epic: Epic?, project: Project, into target: String) async {
        let manager = worktreeManager(for: project)
        let taskBranch = Self.taskBranchPrefix + task.id
        let taskTitle = task.title
        let targetTitle = epic?.title ?? project.baseBranch
        let projectBase = project.baseBranch
        let epicBranch = epic?.branch
        let worktreeName = "merge-\(task.id)"
        var byPullRequest = false
        if epic == nil {
            let settings = project.settings
            let publisher = BranchPublisher(repoPath: URL(fileURLWithPath: project.repoPath))
            byPullRequest = (try? await offMain { publisher.standaloneIntegration(settings) }) == .pullRequest
        }
        let outcome: BranchMerge?
        do {
            outcome = try await offMain {
                if byPullRequest { return try manager.premergeOutcome(taskBranch: taskBranch, into: target) }
                // Only an epic branch is ever cut here. A missing base branch comes back as
                // `.noTargetBranch` instead, because creating one would land the work on a ref
                // nobody pulls and call it done.
                if let epicBranch { try manager.ensureBranch(epicBranch, from: projectBase) }
                return try manager.merge(
                    taskBranch: taskBranch, into: target,
                    taskTitle: taskTitle, targetTitle: targetTitle,
                    worktreeName: worktreeName
                )
            }
        } catch {
            if byPullRequest {
                recordAwaitingPullRequest(task: task, branch: taskBranch, base: target)
                return
            }
            recordLanding(
                task: task, epic: epic, landing: .unlanded,
                detail: "`\(taskBranch)` could not be merged into `\(target)`: \(describe(error))",
                advice: "Merge `\(taskBranch)` into `\(target)` by hand."
            )
            return
        }
        switch outcome {
        case nil:
            recordAwaitingPullRequest(task: task, branch: taskBranch, base: target)
        case .nothingToMerge:
            // No branch is two different facts. `tearDownWorktrees` runs first and deletes a task
            // branch whose work is already in, so "gone" can mean landed; the ledger tip ref, which
            // outlives the branch, is what tells the two apart. A tip that the target does not
            // contain is the worst case of all — the work is now reachable from no branch at all.
            let reaped = (try? await offMain {
                try manager.refCommit(TaskBranchLedger.tipRef(taskId: task.id)).map {
                    (tip: $0, merged: try manager.isMerged(commit: $0, into: "refs/heads/\(target)"))
                }
            }) ?? nil
            switch reaped {
            case .none:
                recordLanding(task: task, epic: epic, landing: .noBranch, detail: nil, advice: nil)
            case .some(let reaped) where reaped.merged:
                recordLanding(
                    task: task, epic: epic, landing: .landed,
                    detail: "`\(taskBranch)` was merged into `\(target)` and reaped.", advice: nil
                )
            case .some(let reaped):
                recordLanding(
                    task: task, epic: epic, landing: .unlanded,
                    detail: "`\(taskBranch)` is gone and `\(target)` does not contain \(reaped.tip).",
                    advice: "Recover the commit with `git branch <name> \(reaped.tip)` and merge it into `\(target)`."
                )
            }
        case .alreadyMerged, .fastForwarded, .merged:
            recordLanding(
                task: task, epic: epic, landing: .landed,
                detail: "`\(taskBranch)` is in `\(target)`.", advice: nil
            )
        case .noTargetBranch(let missing):
            recordLanding(
                task: task, epic: epic, landing: .unlanded,
                detail: "`\(taskBranch)` has nowhere to land: `\(missing)` does not exist in \(project.repoPath).",
                advice: "Create `\(missing)` or correct the project's base branch, then merge `\(taskBranch)` into it."
            )
        case .conflicted(let files):
            let listed = files.isEmpty ? "(git reported no paths)" : files.map { "- `\($0)`" }.joined(separator: "\n")
            recordLanding(
                task: task, epic: epic, landing: .unlanded,
                detail: "`\(taskBranch)` conflicts with `\(target)`, which is unchanged and now behind.",
                advice: "Merge `\(taskBranch)` into `\(target)` and resolve these:\n\(listed)"
            )
        case .skippedCheckedOut(let path):
            recordLanding(
                task: task, epic: epic, landing: .unlanded,
                detail: "`\(taskBranch)` was not merged into `\(target)`: `\(target)` is checked out at \(path), "
                    + "and Agent Board does not move a branch a working tree holds.",
                advice: "Merge `\(taskBranch)` into `\(target)` from that checkout, or open a pull request for it."
            )
        }
    }

    /// A pull request already recorded against the task — opened before the accept — goes straight
    /// to `pullRequestOpen`; otherwise the task waits for one.
    private func recordAwaitingPullRequest(task: BoardTask, branch: String, base: String) {
        if let pr = try? tasks.recordedPullRequest(taskId: task.id) {
            recordLanding(
                task: task, epic: nil, landing: .pullRequestOpen, detail: PullRequestLanding.openDetail(pr), advice: nil
            )
            return
        }
        recordLanding(
            task: task, epic: nil, landing: .awaitingPullRequest,
            detail: PullRequestLanding.awaitingDetail(branch: branch, base: base),
            advice: PullRequestLanding.awaitingAdvice(branch: branch)
        )
    }

    /// SPEC §5: settles each `pullRequestOpen` landing against GitHub. Merged lands the task with the
    /// merge commit, closed unlands it with the reason, and a `gh` failure keeps the landing and puts
    /// the failure in its detail. Runs on the metering tick's first pass after launch and every
    /// `pullRequestCheckIntervalMillis` after, and when the inspector opens the task.
    func refreshPullRequestLandings(projectId: String? = nil, taskId: String? = nil) async {
        do {
            try tasks.adoptRecordedPullRequests(projectId: projectId, taskId: taskId)
        } catch {
            report(["could not adopt recorded pull requests: \(describe(error))"])
        }
        guard let open = try? tasks.openPullRequestLandings(projectId: projectId, taskId: taskId) else { return }
        let reader = pullRequestStates
        var touched: Set<String> = []
        for task in open where !landingChecksInFlight.contains(task.id) {
            guard let pr = task.landingDetail.flatMap(PullRequestReference.init(in:)),
                  let project = try? projects.get(task.projectId)
            else { continue }
            landingChecksInFlight.insert(task.id)
            defer { landingChecksInFlight.remove(task.id) }
            let repo = URL(fileURLWithPath: project.repoPath)
            let url = pr.url
            let state: Result<PullRequestState, Error>
            do {
                state = .success(try await offMain { try reader.state(of: url, cwd: repo) })
            } catch {
                state = .failure(error)
            }
            guard let current = try? tasks.get(task.id), current.column == .done,
                  current.landing == .pullRequestOpen
            else { continue }
            let epic = current.epicId.flatMap { try? epics.get($0) }
            let branch = Self.taskBranchPrefix + current.id
            switch state {
            case .success(.merged(let commit, _)):
                recordLanding(
                    task: current, epic: epic, landing: .landed,
                    detail: PullRequestLanding.mergedDetail(pr, commit: commit), advice: nil
                )
            case .success(.closed):
                recordLanding(
                    task: current, epic: epic, landing: .unlanded,
                    detail: PullRequestLanding.closedDetail(pr, branch: branch),
                    advice: PullRequestLanding.closedAdvice(branch: branch)
                )
                touched.insert(current.projectId)
            case .success(.open):
                keepOpenLanding(current, detail: PullRequestLanding.openDetail(pr))
            case .failure(let error):
                keepOpenLanding(current, detail: PullRequestLanding.openDetail(pr, uncheckedBecause: describe(error)))
            }
        }
        if taskId == nil { touched.formUnion(await refreshEpicPullRequests(projectId: projectId)) }
        for projectId in touched { announceReports(projectId: projectId) }
    }

    /// SPEC §5.2: settles each PR-open epic against GitHub. Merged makes the epic `done`, lands the
    /// done tasks the merged head carries, and unlands those only the local epic branch carries;
    /// closed returns it to `active` with a `decision` report. Returns the projects that gained a report.
    private func refreshEpicPullRequests(projectId: String?) async -> Set<String> {
        guard let checks = try? board.epicPullRequestChecks(projectId: projectId) else { return [] }
        let reader = pullRequestStates
        var touched: Set<String> = []
        for check in checks where !landingChecksInFlight.contains(check.epic.id) {
            guard let project = try? projects.get(check.epic.projectId) else { continue }
            landingChecksInFlight.insert(check.epic.id)
            defer { landingChecksInFlight.remove(check.epic.id) }
            let repo = URL(fileURLWithPath: project.repoPath)
            let url = check.pullRequest.url
            do {
                switch try await offMain({ try reader.state(of: url, cwd: repo) }) {
                case .merged(let commit, let head):
                    let carried = await tasksCarried(by: check.epic, head: head, project: project)
                    if try board.landEpicPullRequest(
                        epicId: check.epic.id, pullRequest: check.pullRequest, commit: commit, carriage: carried
                    ) {
                        touched.insert(project.id)
                    }
                case .closed:
                    if try board.reopenEpicAfterClosedPullRequest(epicId: check.epic.id, pullRequest: check.pullRequest) != nil {
                        touched.insert(project.id)
                    }
                case .open:
                    break
                }
            } catch {
                report(["could not check pull request #\(check.pullRequest.number) for epic \(check.epic.id): \(describe(error))"])
            }
        }
        return touched
    }

    /// Splits the epic's `done` tasks by their tip (branch, or reaped tip): `landed` when the merged
    /// `head` contains it, `late` when only the local epic branch does, neither for a conflicted
    /// merge the integrator never finished. A task with no tip is judged by a commit its landing
    /// detail records, else is `unverified` if marked `.landed`. A `head` that cannot be fetched judges
    /// no task.
    private func tasksCarried(by epic: Epic, head: String?, project: Project) async -> EpicCarriage {
        let members = ((try? tasks.list(projectId: project.id, epicId: epic.id, includeArchived: true)) ?? [])
            .filter { $0.column == .done && $0.landing != .noBranch }
        let manager = worktreeManager(for: project)
        let epicBranch = epic.branch
        do {
            return try await offMain { () -> EpicCarriage in
                guard let head else { return EpicCarriage(headUnresolved: "GitHub reported no head commit") }
                guard try manager.fetchCommitIfMissing(head, from: "origin") else {
                    return EpicCarriage(headUnresolved: "head \(head) could not be fetched from origin")
                }
                var carriage = EpicCarriage()
                for task in members {
                    let tip = try manager.refCommit("refs/heads/" + Self.taskBranchPrefix + task.id)
                        ?? manager.refCommit(TaskBranchLedger.tipRef(taskId: task.id))
                    if let tip {
                        if try manager.isMerged(commit: tip, into: head) {
                            carriage.landed.append(task.id)
                        } else if try manager.isMerged(commit: tip, into: epicBranch) {
                            carriage.late.append(task.id)
                        }
                    } else if try EpicCarriage.recordedCommits(in: task.landingDetail).contains(where: {
                        try manager.commitExists($0) && manager.isMerged(commit: $0, into: head)
                    }) {
                        carriage.landed.append(task.id)
                    } else if task.landing == .landed {
                        carriage.unverified.append(task.id)
                    }
                }
                return carriage
            }
        } catch {
            return EpicCarriage(headUnresolved: describe(error))
        }
    }

    private func keepOpenLanding(_ task: BoardTask, detail: String) {
        guard task.landingDetail != detail else { return }
        recordLanding(task: task, epic: nil, landing: .pullRequestOpen, detail: detail, advice: nil)
    }

    /// The shared branch `task` ran on, or nil when it had a worktree of its own. Read from its
    /// newest session that carries a branch, so a task retried into a worktree after a shared
    /// attempt is treated as the worktree task it now is.
    private func sharedBranch(of task: BoardTask) -> String? {
        guard let rows = try? sessions.forTask(task.id) else { return nil }
        guard let newest = rows.last(where: { $0.branch != nil }) else { return nil }
        guard newest.worktreePath == nil, let branch = newest.branch,
              branch.hasPrefix(SharedCheckoutGroup.branchPrefix)
        else { return nil }
        return branch
    }

    /// Every task that has run on `branch`, newest session state per task.
    private func sharedMembers(projectId: String, branch: String) throws -> [SharedBranchMember] {
        var members: [String: SharedBranchMember] = [:]
        var order: [String] = []
        for row in try sessions.all(projectId: projectId)
        where row.role == .worker && row.worktreePath == nil && row.branch == branch {
            // A discarded member's task row is gone, so there is nobody left to accept it and it
            // cannot hold the branch. Its commits still merge with everyone else's.
            guard let taskId = row.taskId, let task = try tasks.get(taskId) else { continue }
            if members[taskId] == nil {
                order.append(taskId)
                members[taskId] = SharedBranchMember(taskId: taskId, isAccepted: task.column == .done, isLive: false)
            }
            if row.state.isActive { members[taskId]?.isLive = true }
        }
        return order.compactMap { members[$0] }
    }

    /// A shared branch merges into the epic branch once, when its last member is accepted. Until
    /// then the accepted task is recorded as accepted and nothing is merged or reaped: its commits
    /// are interleaved with its siblings' on one ref, so there is no range that is its work alone.
    private func mergeSharedBranch(task: BoardTask, epic: Epic, project: Project, branch: String) async {
        // A sibling accepted concurrently merged the branch first, carrying this task, and reaped it.
        if (try? tasks.get(task.id))??.landing == .landed { return }
        let members = (try? sharedMembers(projectId: project.id, branch: branch)) ?? []
        guard SharedBranchAcceptance.isReadyToMerge(members) else {
            let waiting = SharedBranchAcceptance.waitingOn(members)
            recordLanding(
                task: task, epic: epic, landing: .unlanded,
                detail: "`\(branch)` carries \(members.count) tasks' commits and has not been merged into the "
                    + "epic branch `\(epic.branch)`."
                    + "\nA shared branch merges once, when every task on it has been accepted and no worker is "
                    + "still standing in the checkout: its members' commits are interleaved on one ref, so there "
                    + "is no range that is one task's work alone and Agent Board does not unpick commits."
                    + "\n\nStill outstanding on `\(branch)`:\n"
                    + waiting.map { "- \($0)" }.joined(separator: "\n"),
                advice: nil
            )
            return
        }

        let manager = worktreeManager(for: project)
        let epicBranch = epic.branch
        let epicTitle = epic.title
        let projectBase = project.baseBranch
        let memberIds = members.map(\.taskId)
        let mergeTitle = sharedMergeTitle(memberIds)
        let worktreeName = "merge-shared-\(epic.id)"
        let outcome: BranchMerge
        do {
            outcome = try await offMain {
                try manager.ensureBranch(epicBranch, from: projectBase)
                let base = try manager.mergeBase(branch, epicBranch) ?? projectBase
                // A branch that predates the ledger has its attribution only in its old trailers,
                // and this is the last moment anything reads it: reaping deletes the ref.
                _ = try? manager.backfillFromTrailers(on: branch, since: base)
                // Written before the merge, because the branch is about to be deleted and the refs
                // are all that is left to say which commit was whose.
                try manager.recordSharedLedger(branch: branch, base: base, taskIds: memberIds)
                return try manager.merge(
                    taskBranch: branch, into: epicBranch, taskTitle: mergeTitle,
                    targetTitle: epicTitle, worktreeName: worktreeName
                )
            }
        } catch {
            recordLanding(
                task: task, epic: epic, landing: .unlanded,
                detail: "`\(branch)`, shared by \(memberIds.count) task\(memberIds.count == 1 ? "" : "s"), "
                    + "could not be merged into the epic branch `\(epicBranch)`: \(describe(error))",
                advice: "The epic branch is behind. Dispatch a task to merge `\(branch)` into it by hand."
            )
            return
        }
        switch outcome {
        case .alreadyMerged, .fastForwarded, .merged, .nothingToMerge:
            recordSharedLanding(memberIds, epic: epic, landing: .landed)
            await reapSharedBranch(branch, epic: epic, project: project)
        case .conflicted(let files):
            let listed = files.isEmpty ? "(git reported no paths)" : files.map { "- `\($0)`" }.joined(separator: "\n")
            recordLanding(
                task: task, epic: epic, landing: .unlanded,
                detail: "`\(branch)`, shared by \(memberIds.count) tasks, conflicts with the epic branch "
                    + "`\(epicBranch)`, which is unchanged and now behind."
                    + "\n\nConflicting files:\n\(listed)",
                advice: "Dispatch a task to merge `\(branch)` into `\(epicBranch)` and resolve these. "
                    + "That one merge carries every task on the branch."
            )
        case .skippedCheckedOut(let path):
            recordLanding(
                task: task, epic: epic, landing: .unlanded,
                detail: "`\(branch)`, shared by \(memberIds.count) tasks, was not merged into the epic branch "
                    + "`\(epicBranch)`: `\(epicBranch)` is checked out at \(path), and Agent Board does not move a "
                    + "branch a working tree holds.",
                advice: "Whoever holds it — the integrator, normally — must merge `\(branch)` themselves."
            )
        case .noTargetBranch(let missing):
            recordLanding(
                task: task, epic: epic, landing: .unlanded,
                detail: "`\(branch)`, shared by \(memberIds.count) tasks, has nowhere to land: "
                    + "`\(missing)` does not exist in \(project.repoPath).",
                advice: "Create `\(missing)`, then merge `\(branch)` into it."
            )
        }
    }

    /// A shared branch's members all land at the same moment — the one merge carries every one of
    /// them — so a sibling accepted earlier has its `unlanded` corrected here rather than staying
    /// flagged for a human who has nothing left to do.
    private func recordSharedLanding(_ taskIds: [String], epic: Epic, landing: TaskLanding) {
        for id in taskIds {
            guard let member = (try? tasks.get(id)) ?? nil else { continue }
            recordLanding(task: member, epic: epic, landing: landing, detail: nil, advice: nil)
        }
    }

    /// What the merge commit calls a branch that belongs to several tasks. Never an id: this subject
    /// lands in whatever repository the epic's pull request is opened in (SPEC §5.2).
    private func sharedMergeTitle(_ taskIds: [String]) -> String {
        let titles = taskIds.compactMap { try? tasks.get($0)?.title }.compactMap { $0 }
        guard titles.count != 1 else { return titles[0] }
        return "\(taskIds.count) tasks sharing a checkout"
    }

    /// The project's own checkout is standing on the shared branch, so it has to step off before
    /// git will delete the ref. A dirty checkout keeps the branch rather than losing anything.
    private func reapSharedBranch(_ branch: String, epic: Epic, project: Project) async {
        let manager = worktreeManager(for: project)
        let epicBranch = epic.branch
        let bases = [project.baseBranch, epicBranch]
        let notices = await offMainNotices {
            do {
                try manager.releaseSharedBranch(branch, to: epicBranch)
            } catch {
                return ["kept shared branch \(branch): \(error)"]
            }
            return Self.deleteBranch(manager, branch, bases: bases)
        }
        report(notices)
    }

    /// Writes the landing and, when the human has something to do about it, queues a `decision`
    /// report. The write comes first: a report that fails to insert must not also lose the state
    /// the board renders.
    private func recordLanding(
        task: BoardTask, epic: Epic?, landing: TaskLanding, detail: String?, advice: String?
    ) {
        do {
            try tasks.setLanding(task.id, landing, detail: detail)
        } catch {
            report(["could not record where \(task.id) landed: \(describe(error))"])
        }
        // An open pull request is already in front of the human; the merge check reports if it closes.
        guard landing.needsAttention, landing != .pullRequestOpen, let detail else { return }
        let text = "Task \(task.id) (\(task.title)) was accepted into done, but its branch "
            + detail + (advice.map { "\n" + $0 } ?? "")
        do {
            try ReportStore(db).insert(
                projectId: task.projectId, taskId: task.id, sessionId: nil, kind: .decision, body: text
            )
        } catch {
            report(["could not queue the landing report for \(task.id): \(describe(error))"])
            return
        }
        report([epic.map { "epic \($0.id): " + text } ?? text])
    }

    func reopen(taskId: String) async throws {
        try await recording {
            try await stopLiveSessions(onTask: taskId, by: .human)
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
        refreshSleepAssertion()
    }

    func attachCommand(sessionId: String) -> (executable: String, arguments: [String])? {
        guard let shortId = try? sessions.get(sessionId)?.shortId else { return nil }
        return runtime.attachCommand(shortId: shortId)
    }

    func worktreeDiffstat(taskId: String) async -> String? {
        guard let context = diffContext(taskId: taskId) else { return nil }
        return try? await offMain {
            switch context.site {
            case .worktree(let path):
                return try context.manager.diffstat(worktree: path, against: context.base)
            case .sharedBranch(let branch):
                context.backfillTrailers(branch: branch)
                return try context.manager.diffstat(taskId: taskId, on: branch, since: context.base)
            }
        }
    }

    func worktreeDiffSummary(taskId: String) async -> DiffSummary? {
        guard let context = diffContext(taskId: taskId) else { return nil }
        return try? await offMain {
            switch context.site {
            case .worktree(let path):
                return try context.manager.diffSummary(worktree: path, against: context.base)
            case .sharedBranch(let branch):
                context.backfillTrailers(branch: branch)
                return try context.manager.diffSummary(taskId: taskId, on: branch, since: context.base)
            }
        }
    }

    private enum DiffSite {
        case worktree(URL)
        /// The task's commits are interleaved with its siblings' on one branch, so the diff is
        /// selected by the `task_commit` ledger rather than by the branch's whole range.
        case sharedBranch(String)
    }

    private struct DiffContext {
        var manager: WorktreeManager
        var site: DiffSite
        var base: String
        /// Set for the first shared-branch read of a branch this run, which is the one that turns
        /// pre-ledger `Agent-Board-Task` trailers into rows. Off main, because it runs git.
        var readTrailers: Bool = false

        func backfillTrailers(branch: String) {
            guard readTrailers else { return }
            _ = try? manager.backfillFromTrailers(on: branch, since: base)
        }
    }

    private func diffContext(taskId: String) -> DiffContext? {
        guard let task = try? tasks.get(taskId),
              let project = try? projects.get(task.projectId),
              let taskSessions = try? sessions.forTask(taskId)
        else { return nil }
        let manager = worktreeManager(for: project)
        // A session with no worktree of its own ran in the shared checkout; its branch carries other
        // tasks' commits too. Preferred over any worktree row, because a task that was retried into
        // a worktree keeps that row and the shared path still answers for the shared attempt.
        if let shared = taskSessions.last(where: { $0.worktreePath == nil && $0.branch != nil }),
           let branch = shared.branch {
            return DiffContext(
                manager: manager, site: .sharedBranch(branch), base: project.baseBranch,
                readTrailers: trailersBackfilled.insert("\(project.id)\u{01}\(branch)").inserted
            )
        }
        guard let worktreePath = taskSessions
            .map({ $0.worktreePath ?? $0.cwd })
            .first(where: { FileManager.default.fileExists(atPath: $0) })
        else { return nil }
        return DiffContext(
            manager: manager, site: .worktree(URL(fileURLWithPath: worktreePath)), base: project.baseBranch
        )
    }

    /// A task branch that git no longer has is read from the ledger, never from its own absence:
    /// Agent Board deletes a task branch precisely because its work was merged.
    nonisolated static func branchFacts(
        _ manager: WorktreeManager,
        taskIds: [String],
        epicBranch: String,
        baseBranch: String,
        sharedBranches: [String: String],
        merged: [String: Bool],
        dispatched: Set<String>
    ) throws -> [String: TaskBranchFacts] {
        let epicRef = "refs/heads/\(epicBranch)"
        var facts: [String: TaskBranchFacts] = [:]
        for taskId in taskIds {
            if let shared = sharedBranches[taskId] {
                facts[taskId] = try sharedBranchFacts(
                    manager, taskId: taskId, branch: shared, epicBranch: epicBranch,
                    epicRef: epicRef, baseBranch: baseBranch
                )
                continue
            }
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

    /// A shared branch belongs to no one task, so every count here is selected by the commit ledger
    /// rather than by the branch's range. Once the branch is reaped, the same selection still works
    /// against the epic branch, where the commits now live.
    private nonisolated static func sharedBranchFacts(
        _ manager: WorktreeManager,
        taskId: String,
        branch: String,
        epicBranch: String,
        epicRef: String,
        baseBranch: String
    ) throws -> TaskBranchFacts {
        var fact = TaskBranchFacts(branchExists: try manager.branchExists(branch), sharedBranch: branch)
        fact.recordedBase = try manager.refCommit(TaskBranchLedger.baseRef(taskId: taskId))
        fact.recordedTip = try manager.refCommit(TaskBranchLedger.tipRef(taskId: taskId))
        if fact.branchExists {
            let base = try fact.recordedBase ?? manager.mergeBase(branch, epicBranch) ?? baseBranch
            let own = try manager.commits(taskId: taskId, on: branch, since: base)
            fact.ownCommits = own.count
            fact.recordedTip = fact.recordedTip ?? own.first
            fact.mergedIntoEpic = try !own.isEmpty && own.allSatisfy { try manager.isMerged(commit: $0, into: epicRef) }
            return fact
        }
        guard let base = fact.recordedBase, let tip = fact.recordedTip else { return fact }
        fact.tipOnEpicBranch = try manager.isMerged(commit: tip, into: epicRef)
        fact.ownCommits = try manager.commits(taskId: taskId, on: epicBranch, since: base).count
        return fact
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
        let manager = worktreeManager(for: project)
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
        let manager = worktreeManager(for: project)
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
        let manager = worktreeManager(for: project)
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

    /// The only way this type builds a `WorktreeManager`. It is always ledger-backed: a second
    /// spelling here is what made attribution depend on which call site a caller happened to copy.
    func worktreeManager(for project: Project) -> WorktreeManager {
        WorktreeManager(
            repoPath: URL(fileURLWithPath: project.repoPath),
            worktreeRoot: URL(fileURLWithPath: project.worktreeRoot),
            attribution: .ledger(TaskCommitStore(db))
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
            .filter { !$0.hasPrefix(EpicStore.branchPrefix) && !$0.hasPrefix(SharedCheckoutGroup.branchPrefix) }
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

    /// The live shell pid per project, for anything that has to recognise a process the board
    /// started. Not on `WorkerSupervising`: a stub conformer has no shell to report, and the one
    /// caller holds the concrete supervisor.
    func shellConsolePIDs() -> [String: pid_t] {
        shellConsoles.compactMapValues(\.shellPID)
    }

    func shellConsole(projectId: String) throws -> ShellConsole {
        if let existing = shellConsoles[projectId] { return existing }
        guard try projects.get(projectId) != nil else { throw SupervisorError.projectNotFound(projectId) }
        let console = ShellConsole(projectId: projectId, db: db)
        shellConsoles[projectId] = console
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
                let result = try await offMain {
                    try publisher.push(
                        branch: request.branch, publishedAs: request.publishedBranch, remote: request.remote
                    )
                }
                try board.recordPublished(approval: approval, summary: "Push approved: \(result.summary).")
            case .pullRequest:
                let result = try await offMain {
                    try publisher.openPullRequest(
                        branch: request.branch, publishedAs: request.publishedBranch, base: base,
                        title: request.title ?? request.branch, body: request.body ?? "", remote: request.remote
                    )
                }
                let verb = result.alreadyOpen ? "Pull request already open" : "Pull request opened"
                let from = request.head == request.branch
                    ? request.branch
                    : "\(request.head) (local \(request.branch))"
                try board.recordPublished(
                    approval: approval,
                    summary: "\(verb) from \(from) into \(base).",
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
            let report = try board.closeEpic(epicId: epicId, as: closure, by: .human)
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
            // The same name the approved path would publish, so the button does not aim the compare
            // page at a ref the remote does not have under that name.
            let head = try RemoteBranchResolver(db).publishedName(branch: epic.branch, project: project)
                ?? epic.branch
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

    func assignAgent(
        taskId: String, rosterAgentId: String, scope: AgentBoardCore.TokenScope
    ) async throws -> WorkerSpawn {
        try await recording { try await spawn(taskId: taskId, rosterAgentId: rosterAgentId, scope: scope) }
    }

    /// Only the orchestrator's `stop_worker` reaches this; a human's Stop calls `stop(sessionId:)`.
    func stopWorker(sessionId: String) async throws {
        try await recording { try await stopSession(sessionId, by: .orchestrator(sessionId: nil)) }
    }

    // MARK: - BoardEventSink

    func notify(projectId: String, title: String, body: String) async {
        await notify(projectId: projectId, sessionId: nil, title: title, body: body)
    }

    /// The only producer of this event is the hook sink's "Agent needs input" path, which fires
    /// when a worker asked for input and nothing marked a task blocked — the blocked-worker
    /// category by any other name.
    func notify(projectId: String, sessionId: String?, title: String, body: String) async {
        post(
            title, body: body, projectId: projectId, category: .blockedWorkers,
            subject: sessionId.map(NotificationRoute.Subject.session) ?? .project
        )
    }

    /// Every banner Agent Board raises goes through here, so none of them can reach the human
    /// without saying which project it is about, without carrying the route a click follows back
    /// to it, or against that project's notification preferences.
    private func post(
        _ title: String, body: String, projectId: String?, category: NotificationCategory,
        subject: NotificationRoute.Subject = .project
    ) {
        guard shouldNotify(projectId: projectId, category: category) else { return }
        postBanner(
            notificationTitle(title, projectId: projectId),
            body,
            projectId.map { NotificationRoute(projectId: $0, subject: subject) }
        )
    }

    /// `MacNotifier.post` is inert under `xctest`, because the runner is not an app bundle. Every
    /// banner leaves through here so a test can see which ones the categories let past and what
    /// route each one carries.
    @ObservationIgnored var postBanner: @MainActor (String, String, NotificationRoute?) -> Void = {
        MacNotifier.shared.post(title: $0, body: $1, route: $2)
    }

    /// The gating decision for every banner that is not driven by the attention signal.
    /// `MacNotifier.post` is inert under `xctest`, so this is what the tests assert on.
    /// A project that has gone missing keeps the default, which is to notify.
    func shouldNotify(
        projectId: String?, category: NotificationCategory, now: Int64 = .nowMillis
    ) -> Bool {
        notificationPreferences(projectId).allows(category, now: now)
    }

    private func notificationPreferences(_ projectId: String?) -> NotificationPreferences {
        guard let projectId, let project = (try? projects.get(projectId)) ?? nil else {
            return NotificationPreferences()
        }
        return project.settings.notifications
    }

    /// `MacNotifier.post` is inert under `xctest`, so the naming is asserted here instead.
    func notificationTitle(_ headline: String, projectId: String?) -> String {
        NotificationText.title(headline, project: projectId.flatMap(projectName))
    }

    private func projectName(_ id: String) -> String? {
        (try? projects.get(id))??.name
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

    /// The orderly end of a worker's life, after `report_complete` or a reviewer's verdict, and until
    /// now the only one that left its process running: the agent is told to take no further turns, so the session sits `idle` holding its whole
    /// context forever. Stopping it frees ~300 MB and costs nothing — `claude --bg --resume` reads
    /// the transcript, which a stop leaves intact, so the task in `review` can still be reopened
    /// and attached to.
    func workerCompleted(projectId: String, sessionId: String) async {
        guard let session = try? sessions.get(sessionId), let shortId = session.shortId else { return }
        try? await runtime.stop(shortId: shortId)
    }

    /// Stops the agent of every session this board's own rows say is finished — the backlog left by
    /// every worker that completed before `report_complete` learned to stop its own session.
    ///
    /// Every target comes from `agent_session`, and the runtime list read afterwards can only
    /// subtract. A `claude` session with no row here is never a candidate, whatever its process
    /// looks like: argv and environment cannot tell a parked spare from a session doing real work.
    @discardableResult
    func sweepLeakedAgents(dryRun: Bool = false) async -> AgentSweepReport {
        var report = AgentSweepReport(dryRun: dryRun)
        let rows = ((try? projects.list()) ?? []).flatMap { (try? sessions.all(projectId: $0.id)) ?? [] }
        let listed = try? await runtime.listSessions()
        // A registry entry without a pid has no process to free. Measured on this machine: of 124
        // inactive rows `claude stop` accepted, the 8 carrying a pid were the whole 1,311 MB, and
        // the other 116 cost 60s of the 71s the sweep took and moved nothing.
        let resident = listed.map { Set($0.filter { $0.pid != nil }.compactMap(\.id)) }
        report.runtimeListed = listed != nil
        for decision in LeakedAgentSweep.plan(rows) {
            guard decision.outcome == .stop, let shortId = decision.shortId else {
                report.kept.append(decision)
                continue
            }
            if let resident, !resident.contains(shortId) {
                report.kept.append(LeakedAgentSweep.Decision(
                    sessionId: decision.sessionId, shortId: shortId, outcome: .keep,
                    reason: "the runtime reports no process for this short id"
                ))
                continue
            }
            if dryRun {
                report.wouldStop.append(decision)
                continue
            }
            do {
                try await runtime.stop(shortId: shortId)
                report.stopped.append(decision)
            } catch {
                report.failed.append(LeakedAgentSweep.Decision(
                    sessionId: decision.sessionId, shortId: shortId, outcome: .stop,
                    reason: describe(error)
                ))
            }
        }
        if let listed {
            let known = Set(rows.compactMap(\.shortId))
            report.untracked = listed
                .filter { $0.pid != nil && $0.id.map { !known.contains($0) } ?? true }
                .count
        }
        return report
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
        raiseAttentionBanners(now: now)
        if now - lastArchiveSweep >= Self.archiveSweepIntervalMillis {
            lastArchiveSweep = now
            sweepArchives(all, now: now)
        }
        if now - lastPullRequestCheck >= Self.pullRequestCheckIntervalMillis {
            lastPullRequestCheck = now
            _Concurrency.Task { await self.refreshPullRequestLandings() }
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
        refreshSleepAssertion(all)
    }

    /// Driven by the observed `agent_session` rows and nothing else, so a worker that died without
    /// reporting stops holding the Mac awake the moment `reconcile` or the leaked-agent sweep flips
    /// its row inactive — there is no spawn-side counter that could be left one too high. SPEC §8.3.
    func refreshSleepAssertion(_ all: [Project]? = nil) {
        guard let sleepGuard else { return }
        let projectList = all ?? ((try? projects.list()) ?? [])
        sleepGuard.apply(projectList.flatMap { ((try? sessions.all(projectId: $0.id)) ?? []).map(\.state) })
    }

    /// A pending approval and a blocked worker each stop work outright and nothing else announces
    /// them, so the same signal the sidebar badge reads raises the banner. `AttentionNotifier` owns
    /// the once-per-transition rule, so a queue nobody has answered does not banner every 5s.
    /// Each project's own notification preferences decide which of its banners survive. They gate
    /// the banner alone: `attention.all` is read unchanged, so a muted project's sidebar badge and
    /// At a Glance row say exactly what they said before.
    @discardableResult
    func raiseAttentionBanners(now: Int64 = .nowMillis) -> [AttentionNotice] {
        guard let projects = try? attention.all(now: now) else { return [] }
        let preferences = notificationPreferencesByProject()
        let raised = attentionNotifier.notices(
            for: projects,
            focused: onScreenProject,
            now: now,
            preferences: { preferences[$0] ?? NotificationPreferences() }
        )
        for notice in raised {
            postBanner(notice.title, notice.body, NotificationRoute(notice))
        }
        return raised
    }

    private func notificationPreferencesByProject() -> [String: NotificationPreferences] {
        guard let all = try? projects.list() else { return [:] }
        return Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.settings.notifications) })
    }

    /// A banner for the project already filling the screen is noise. Only the frontmost app counts:
    /// a selection left behind a browser window is not something the human is looking at.
    /// An `xctest` process runs at activation policy `.prohibited`, so `NSApplication.shared
    /// .isActive` is false there and can never be true; a test that needs the suppressed case
    /// replaces `isFrontmost`.
    private var onScreenProject: String? {
        isFrontmost() ? focusedProject : nil
    }

    @ObservationIgnored var isFrontmost: @MainActor () -> Bool = { NSApplication.shared.isActive }

    func focusChanged(projectId: String?) {
        focusedProject = projectId
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

    /// Internal rather than private so a test can drive a single session's stall/cap evaluation
    /// directly, the way `sweepArchives` is exposed for the archive tick.
    func meter(_ session: AgentSession, limits: CapLimits, stallSeconds: Int, awake: AwakeElapsed) async {
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
            toolStartedAt: current.toolStartedDate,
            awake: awake,
            limits: Self.exempting(limits, rostered: current.isRostered),
            state: current.state
        ) else { return }
        await enforce(breach, on: current, awake: awake)
    }

    /// SPEC §12 case 2: a grandchild process waiting on stdin fires no hook, so a `running` worker whose
    /// activity clock has frozen is only surfaced — never killed. The idle cap still decides that.
    private func noteStall(_ session: AgentSession, lastActivity: Date?, stallSeconds: Int, awake: AwakeElapsed) {
        let stalled = session.state == .running && AttentionSelection.isStalled(
            lastActivity: lastActivity,
            startedAt: session.startedDate,
            toolStartedAt: session.toolStartedDate,
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
        post(
            "Worker may be stuck",
            body: "\(session.displayShortId) has made no tool call in \(stallSeconds)s — \(title ?? "no task"). Attach to check.",
            projectId: session.projectId,
            category: .capsAndStalls,
            subject: .session(session.sessionId)
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
        post(
            "Worker stopped at cap", body: description, projectId: session.projectId,
            category: .capsAndStalls, subject: .session(session.sessionId)
        )
    }

    private static func capLimits(_ caps: Caps) -> CapLimits {
        CapLimits(
            maxTokens: caps.maxTokensPerAgent,
            maxWallClockSeconds: caps.maxWallClockSeconds,
            maxIdleSeconds: caps.maxIdleSeconds
        )
    }

    /// A rostered agent runs without the elapsed and idle caps: the epic decided no caps apply to
    /// the roster for now. The token cap survives — it meters spend, not liveness.
    static func exempting(_ limits: CapLimits, rostered: Bool) -> CapLimits {
        guard rostered else { return limits }
        return CapLimits(maxTokens: limits.maxTokens, maxWallClockSeconds: nil, maxIdleSeconds: nil)
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

    /// Returns `expected` rather than the path `git worktree list` prints, which on macOS resolves
    /// `/var` to `/private/var`. Reusing a worktree would otherwise record a second spelling of one
    /// directory on the new session row, and `worktree_path` is compared as a string to decide
    /// whether anyone is already in it.
    private nonisolated static func existingWorktree(_ manager: WorktreeManager, name: String) throws -> URL? {
        let expected = manager.worktreeRoot.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: expected.path) else { return nil }
        let expectedPath = expected.standardizedFileURL.resolvingSymlinksInPath().path
        let listed = try manager.list()
            .first { $0.path.standardizedFileURL.resolvingSymlinksInPath().path == expectedPath }
        return listed == nil ? nil : expected
    }

    /// The commit step differs by placement: `git commit` is refused in a shared checkout, so a
    /// resumed co-resident worker told to "commit on this branch" is sent at a command that fails.
    static func resumePrompt(previousStop: String?, placement: WorkerPlacement = .worktree) -> String {
        var lines = ["Agent Board resumed this session. Continue your task from where you left off; check `git status` and `git log` first."]
        if let previousStop, !previousStop.isEmpty {
            lines.append("The previous run was stopped by Agent Board: \(previousStop).")
        }
        let commit = placement.sharedBranch == nil
            ? "commit on this branch"
            : "commit by calling `\(OpeningPrompt.commitToolName)`"
        lines.append(
            "When finished: \(commit), do not push, call `report_complete`. "
            + "If a resume or a compaction has left you without the instructions you were spawned with, "
            + "read the MCP resource `\(BriefingResourceURI.worker)` — it returns them in full."
        )
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
        notes: SpawnNotes = SpawnNotes(),
        verification: VerificationCommands = VerificationCommands(),
        placement: WorkerPlacement = .worktree,
        workingDirectory: String? = nil,
        agent: AgentIdentity? = nil,
        reviewFindings: String? = nil,
        comments: [TaskComment] = []
    ) -> String {
        OpeningPrompt.compose(
            task: task, branch: branch, attempt: attempt, epicGoal: epicGoal, notes: notes,
            verification: verification, placement: placement, workingDirectory: workingDirectory,
            agent: agent, reviewFindings: reviewFindings, comments: comments
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
