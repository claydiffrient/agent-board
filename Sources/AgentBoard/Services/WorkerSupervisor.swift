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
    case noReviewToRerun(title: String)
    case integrationNotRosterable(title: String)
    case capRefused(String)
    case taskAlreadyHeld(title: String, sessionId: String)
    case worktreeAlreadyHeld(path: String, sessionId: String)
    case shutdownOrdered
    case noShutdownOrder
    case serverNotRunning
    case spawnFailed(worktree: String, underlying: String)
    case setupInterrupted
    case setupStillRunning(title: String, path: String)
    case taskBeingDiscarded(taskId: String)
    case worktreeBeingRemoved(path: String)
    case approvalNotFound(String)
    case rosterAgentNotUsable(id: String, projectName: String)
    case epicCloseRefused(String)
    case epicStillOpen(String)
    case globalShutdownIncomplete([String])
    case dependencyNotOnBranch(dependencyId: String, title: String, commit: String, branch: String, landing: TaskLanding?)
    case watchNotFound(String)
    case triageTaskNotAssignable(title: String)
    case triageNotResumable(title: String)
    case pullRequestNotFetched(String)
    case fixRoundNotFound(title: String)
    case fixRoundNotAcceptable(title: String)

    var errorDescription: String? {
        switch self {
        case .approvalNotFound(let id): return "approval \(id) not found"
        case .watchNotFound(let id): return "watched pull request \(id) not found"
        case .triageTaskNotAssignable(let title):
            return "\"\(title)\" is a pull request triage or follow-up check; only Agent Board's follow-through starts one"
        case .triageNotResumable(let title):
            return "\"\(title)\" is a pull request triage or follow-up check, which is not resumed; follow-through "
                + "starts a fresh one"
        case .pullRequestNotFetched(let reason): return "the pull request could not be fetched: \(reason)"
        case .fixRoundNotFound(let title): return "\"\(title)\" is not a pull request round's fix task"
        case .fixRoundNotAcceptable(let title):
            return "\"\(title)\" is a pull request fix round; its check accepts it, and Agent Board pushes it to the "
                + "pull request rather than merging it"
        case .rosterAgentNotUsable(let id, let projectName):
            return "roster agent \(id) is not in \(projectName)'s usable set; enable it for this project first"
        case .epicCloseRefused(let reason): return reason
        case .epicStillOpen(let id):
            return "epic \(id) is still open; only a done or abandoned epic's worktrees are removed from its lane"
        case .epicNotFound(let id): return "epic \(id) not found"
        case .notAGitRepository(let path): return "\(path) is not a git repository"
        case .projectNotFound(let id): return "project \(id) not found"
        case .taskNotFound(let id): return "task \(id) not found"
        case .sessionNotFound(let id): return "session \(id) not found"
        case .sessionHasNoShortId(let id): return "session \(id) has no claude short id yet; reconcile first"
        case .taskNotAssignable(let title, let column): return "\"\(title)\" is in \(column.rawValue) and cannot be assigned"
        case .noReviewToRerun(let title):
            return "\"\(title)\" is not in review with a rostered reviewer, so there is no review to re-run"
        case .integrationNotRosterable(let title):
            return "\"\(title)\" is an integration task, which a roster agent cannot run; call spawn_worker "
                + "to respawn its integrator on the epic checkout, or request_integration to start a new one"
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
        case .setupStillRunning(let title, let path):
            return "an earlier attempt at \"\(title)\" is still setting up \(path), running the repository's "
                + "post-checkout hook or removing what a failed one left; spawn again once a report says that "
                + "setup has ended: the attempt's failed report, or, for an attempt that was stopped, a report "
                + "saying its setup ended. If its worker starts instead, the task is held and needs no retry"
        case .taskBeingDiscarded(let id): return "task \(id) is being discarded, so no agent is started for it"
        case .worktreeBeingRemoved(let path):
            return "\(path) is being removed by a cleanup that claimed it first, so a session resumed there would "
                + "lose its checkout; spawn the task again instead, which waits for the removal and creates a fresh worktree"
        case .globalShutdownIncomplete(let failures):
            return "some projects could not be wound down:\n" + failures.joined(separator: "\n")
        case .dependencyNotOnBranch(let id, let title, let commit, let branch, let landing):
            let next: String
            switch landing {
            case .unlanded?:
                next = "Its landing is `unlanded`: the accept's merge failed or was skipped and will not run again. "
                    + "Merge \(commit) into `\(branch)`, or dispatch a task to, then spawn again."
            case .pending?, nil:
                next = "Its landing is not settled, so the accept's merge may still be running. A merge that "
                    + "succeeds sends no report, so do not wait for one: spawn again once "
                    + "`git merge-base --is-ancestor \(commit) \(branch)` exits 0. If the landing turns "
                    + "`unlanded` instead, merge \(commit) into `\(branch)` first."
            case let other?:
                next = "Its landing says `\(other.rawValue)`, but `\(branch)` lacks the commit, so the branch moved "
                    + "after the accept. Merge \(commit) into `\(branch)`, then spawn again."
            }
            return "spawn refused: this task depends on \(id) (\"\(title)\"), which was accepted, but its commit "
                + "\(commit) is not on `\(branch)`. A worker cut from `\(branch)` now would start without it. "
                + next
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
    @ObservationIgnored private let coordinatorDir: URL
    @ObservationIgnored private let home: URL
    /// The `claude` every PTY console runs; a test substitutes a script.
    @ObservationIgnored private let claude: ClaudeInvocation
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
    @ObservationIgnored private let messages: MessageStore
    @ObservationIgnored private let requests: RequestStore
    @ObservationIgnored private let fileLocks: FileLockStore
    @ObservationIgnored private let attention: ProjectAttentionStore
    @ObservationIgnored private let pullRequestStates: PullRequestStateReader
    @ObservationIgnored private let pullRequestWatch: PullRequestWatchReader
    @ObservationIgnored private let pullRequestReplies: PullRequestReplier
    @ObservationIgnored private let prWatches: PRWatchStore
    /// Millis of the last PR follow-through poll; 0 means none yet.
    @ObservationIgnored private var lastPRWatchPoll: Int64 = 0
    @ObservationIgnored private var prWatchPoll: _Concurrency.Task<Void, Never>?
    @ObservationIgnored private var prWatchSearchFailures = 0
    /// Consecutive polls on which git could not read a project's `origin`, by project id.
    @ObservationIgnored private var prWatchRemoteFailures: [String: Int] = [:]
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
    /// Millis of the last orphan reap on the tick. `start()` sets it, so the first one waits an interval.
    @ObservationIgnored private var lastOrphanReap: Int64 = 0
    /// One `reconcile` or tick reap per project at a time, so two passes never choose orphans at once (SPEC §5).
    @ObservationIgnored private var worktreeSweeps: [String: _Concurrency.Task<Void, Never>] = [:]
    /// Sessions already announced as stalled, so the tick notifies on the transition, not every 5s.
    @ObservationIgnored private var stallNotified: Set<String> = []
    /// One per metered session, so a tick reads only what each transcript appended since the last (SPEC §7).
    @ObservationIgnored private var transcriptTailers: [String: TranscriptTailer] = [:]
    /// `<project-id>\u{01}<branch>` for each shared branch whose pre-ledger `Agent-Board-Task`
    /// trailers have already been read back this run.
    @ObservationIgnored private var trailersBackfilled: Set<String> = []
    @ObservationIgnored private var consoles: [String: OrchestratorConsole] = [:]
    /// The active Coordinator session's console, if one is running (SPEC §9.4). Replies queued while
    /// it is nil wait in the Coordinator's queue and are announced after the next session's first turn.
    @ObservationIgnored var coordinatorConsole: (any ReportAnnouncing)?
    @ObservationIgnored private var coordinatorConsoleInstance: OrchestratorConsole?
    @ObservationIgnored private let coordinator: CoordinatorStore
    @ObservationIgnored private var shellConsoles: [String: ShellConsole] = [:]
    /// Keyed by setup session id, so a test — or a human stopping a worker mid-setup — can wait on
    /// or cancel the half of a spawn that outlives the call.
    @ObservationIgnored private var setupTasks: [String: _Concurrency.Task<Void, Never>] = [:]
    /// Teardowns running behind a project's teardown hook, which outlast the call that started them (SPEC §5).
    @ObservationIgnored private var teardownTasks: [UUID: _Concurrency.Task<Void, Never>] = [:]
    /// Resolved paths of worktrees some teardown is removing now. No other removal touches them, so
    /// a teardown hook never runs twice in one worktree (SPEC §3.1).
    @ObservationIgnored private var tearingDown: Set<String> = []
    @ObservationIgnored private var teardownWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    /// Worktree paths a spawn is setting up, from before it touches git until setup ends. A reap keeps
    /// them, since a new worktree is clean and at its base, and a second spawn for the task is refused (SPEC §5).
    @ObservationIgnored private var placing: Set<String> = []
    /// Runs once a spawn's worktree exists and before its agent launches, so a test can act in that gap.
    @ObservationIgnored var afterCheckoutCreated: @MainActor () async -> Void = {}
    /// Runs while a spawn holds its mark and before `git worktree add`, so a test can act in that gap.
    @ObservationIgnored var beforeCheckoutCreated: @MainActor () async -> Void = {}
    /// Off in a test that drives every `pollPRWatches()` itself, so the tick's poll cannot advance a watch between two of its own.
    @ObservationIgnored var pollsPRWatchesOnTick = true
    /// Tasks a discard is waiting out the setup of; that setup's end is not a cue to retry.
    @ObservationIgnored private var discarding: Set<String> = []
    /// A resume starts the process before it moves the task back to `running`, so until then its
    /// session looks like a stray one on a settled task to `reconcile`.
    @ObservationIgnored private var resuming: Set<String> = []
    /// When a human last opened a terminal on each session. `claude attach` resumes a stopped one.
    @ObservationIgnored private var attachRequestedAt: [String: Int64] = [:]
    /// The last integration each project's `origin` resolved to, kept for when git fails to read it.
    @ObservationIgnored private var integrationDefaults: [String: StandaloneIntegration] = [:]

    nonisolated static let taskBranchPrefix = TaskStore.branchPrefix
    static let meteringInterval: Duration = .seconds(5)
    /// The archive policies are day-granular, so they ride the metering tick at a far coarser
    /// cadence rather than paying for a scan every 5 seconds — or a second timer.
    static let archiveSweepIntervalMillis: Int64 = 5 * 60 * 1000
    static let orphanReapIntervalMillis: Int64 = 3 * 60 * 1000
    static let pullRequestCheckIntervalMillis: Int64 = 10 * 60 * 1000
    static let prWatchPollIntervalMillis: Int64 = 60 * 1000
    static let prWatchFailuresBeforeAttention = 10
    /// Sessions that ended this recently still get one more transcript read so final spend lands.
    static let finalSpendWindowMillis: Int64 = 15_000

    init(
        db: AppDatabase,
        runtime: any AgentRuntime,
        server: BoardServer,
        appSupportDir: URL,
        worktreeBase: URL,
        projectsRoot: URL = ClaudeProjectPaths.defaultProjectsRoot,
        coordinatorDir: URL = SupportPaths.coordinatorDir(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        claude: ClaudeInvocation = .installed(),
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
        self.coordinatorDir = coordinatorDir
        self.home = home
        self.claude = claude
        coordinator = CoordinatorStore(db)
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
        roster = RosterStore(db, definitions: AgentDefinitionDirectories(home: home))
        board = Board(db)
        archives = ArchiveSweep(db)
        messages = MessageStore(db)
        requests = RequestStore(db)
        fileLocks = FileLockStore(db)
        attention = ProjectAttentionStore(db)
        pullRequestStates = PullRequestStateReader(gh: gh)
        pullRequestWatch = PullRequestWatchReader(gh: gh)
        pullRequestReplies = PullRequestReplier(gh: gh)
        prWatches = PRWatchStore(db)
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
        stopOrphanedCoordinatorSessions()
        sweepStaleFileLocks()
        await sweepLeakedAgents()
        await migrateWorktreeRoots()
        refreshSleepAssertion()
        lastOrphanReap = sleepLedger.reading().nowMillis
        startMetering()
    }

    /// The other half of `start()`: releases the real port `server` bound and cancels the metering
    /// loop. Every test fixture that calls `start()` must call this in teardown, or the Hummingbird
    /// event loop and the 5-second metering `Task` outlive the test and pile up across a run — this
    /// is what left dozens of listening ports and metering loops running behind a hung `swift test`.
    func stop() async {
        meteringTask?.cancel()
        meteringTask = nil
        await server.stop()
    }

    /// A project kept on its old root is reported on every launch until its worktrees are gone (SPEC §4).
    @discardableResult
    func migrateWorktreeRoots() async -> WorktreeRootMigration.Outcome {
        let migration = WorktreeRootMigration(db: db, worktreeBase: worktreeBase, home: home)
        let outcome = await _Concurrency.Task.detached(priority: .userInitiated) { migration.run() }.value
        for line in outcome.migrated {
            FileHandle.standardError.write(Data("worktree root migrated: \(line)\n".utf8))
        }
        for line in outcome.skipped {
            FileHandle.standardError.write(Data("worktree root not migrated: \(line)\n".utf8))
        }
        report(outcome.skipped)
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
        // A worker or reviewer grant on a triage or follow-up check task would hold authority over the PR's
        // checkout that the triager scope exists to withhold.
        guard !task.origin.isPullRequestReader else { throw SupervisorError.triageTaskNotAssignable(title: task.title) }
        guard task.column != .running, task.column != .done, task.column != .closed else {
            throw SupervisorError.taskNotAssignable(title: task.title, column: task.column)
        }
        // SPEC §5.2 step 3: a respawned integrator runs where the first one did, on the epic branch.
        if task.origin == .integration, scope == .worker, rosterAgentId != nil {
            throw SupervisorError.integrationNotRosterable(title: task.title)
        }
        if task.origin == .integration, let epicId = task.epicId, scope == .worker {
            let placeholder = try await spawnIntegrator(epicId: epicId, retrying: task)
            return WorkerSpawn(
                setupSessionId: placeholder.sessionId, worktreePath: placeholder.cwd,
                branch: placeholder.branch ?? ""
            )
        }
        guard let project = try projects.get(task.projectId) else {
            throw SupervisorError.projectNotFound(task.projectId)
        }
        guard let port = serverPort else { throw SupervisorError.serverNotRunning }
        try requireNoShutdown(projectId: project.id)
        if case .refused(let reason) = try CapCheck(db).canSpawn(projectId: project.id) {
            throw SupervisorError.capRefused(reason)
        }
        if task.origin == .fixRound, scope == .worker {
            return try await spawnFixer(task: task, rosterAgentId: rosterAgentId, project: project, port: port)
        }
        if task.origin == .fixRound, scope == .reviewer, let rosterAgentId {
            return try await spawnRoundReviewer(task: task, rosterAgentId: rosterAgentId, project: project, port: port)
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
        // SPEC §3.1: an earlier attempt's checkout may still be running its hook or its rollback,
        // and this attempt would adopt that worktree only to have the rollback delete it.
        let pendingWorktree = manager.worktreeRoot.appendingPathComponent(taskId).path
        guard !placing.contains(pendingWorktree) else {
            throw SupervisorError.setupStillRunning(title: task.title, path: pendingWorktree)
        }
        placing.insert(pendingWorktree)
        var setupHoldsMark = false
        defer { if !setupHoldsMark { placing.remove(pendingWorktree) } }
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
        var baseWarnings: [String] = []
        if let epic {
            let epicBranch = epic.branch
            let projectBase = project.baseBranch
            // SPEC §3.1 step 1: only a new epic branch looks at the remote; an existing one is local
            // integration state its tasks branch from as it stands.
            let cut = try await offMain { () -> String? in
                guard try !manager.branchExists(epicBranch) else { return nil }
                let start = manager.freshestBase(projectBase)
                try manager.ensureBranch(epicBranch, from: start.ref)
                return start.warning
            }
            baseWarnings += [cut].compactMap { $0 }
            base = epicBranch
            if scope != .reviewer, placement.sharedBranch == nil {
                try await requireDependenciesOnEpicBranch(task: task, epic: epic, manager: manager)
            }
        } else {
            base = project.baseBranch
        }
        var site = try await checkoutSite(
            project: project, taskId: taskId, placement: placement, base: base,
            cutsFromProjectBase: epic == nil, manager: manager, warnings: warnings
        )
        // A reviewer judges the checkout before its session exists, so it cannot wait for setup.
        if scope == .reviewer, let pending = site.pending {
            try await createWorktree(pending)
            site.pending = nil
            await afterCheckoutCreated()
        }
        report(baseWarnings)
        site.warnings += baseWarnings
        let branch = site.branch
        // A handed-off task keeps its worktree on disk, so a second agent could otherwise be launched
        // into a checkout someone is still working in. Co-resident agents in a shared checkout are
        // deliberate and have no worktree path, so this skips them.
        if let path = site.worktreePath, let holder = try sessions.activeHolder(worktreePath: path) {
            throw SupervisorError.worktreeAlreadyHeld(path: path, sessionId: holder.sessionId)
        }
        // SPEC §3.1 step 1: a standalone branch cut from the remote's base diffs against that cut
        // point while local base is behind it, or the remote's commits read as the task's work.
        let reviewBase = scope == .reviewer && epic == nil
            ? try await offMain { manager.diffBase(taskId: taskId, base: base) }
            : base
        // SPEC §5.1: a reviewer judges the diff and nothing else, so an empty one — a task whose
        // deliverable is a note, say — goes to a person rather than to a reviewer that could only reopen it.
        if scope == .reviewer {
            let cwd = site.cwd
            guard try await offMain({ try ReviewCheckout.hasDiff(against: reviewBase, in: cwd) }) else {
                throw NothingToReview(reason: "Branch `\(branch)` has no diff against `\(reviewBase)`, so there is no "
                    + "code for a rostered reviewer to judge. A task whose deliverable is not code, such as an "
                    + "Agent Board note, needs a person to review it.")
            }
        }

        do {
            let reviewHead = scope == .reviewer
                ? try await offMain { try ReviewCheckout.baseline(in: site.cwd) }
                : nil
            let row = Self.setupRow(
                projectId: project.id, taskId: taskId, site: site, attempt: attempt,
                rosterAgentId: agent?.id, reviewHead: reviewHead, reviewBase: scope == .reviewer ? reviewBase : nil
            )
            // SPEC §5: a discard that began during this spawn's awaits saw no session to stop, and
            // would delete the task under a worktree this setup goes on to create.
            guard !discarding.contains(taskId) else { throw SupervisorError.taskBeingDiscarded(taskId: taskId) }
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
                            task: task, branch: branch, base: reviewBase,
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
                port: port,
                checkout: site.pending,
                placingMark: pendingWorktree
            )
            setupHoldsMark = true
            return WorkerSpawn(
                setupSessionId: placeholder.sessionId, worktreePath: site.cwd.path, branch: branch,
                sharesCheckout: site.placement.sharedBranch != nil, warnings: site.warnings
            )
        } catch SupervisorError.taskBeingDiscarded(let id) {
            throw SupervisorError.taskBeingDiscarded(taskId: id)
        } catch {
            throw SupervisorError.spawnFailed(worktree: site.cwd.path, underlying: describe(error))
        }
    }

    /// SPEC §5: a new worktree for an epic task is cut from the epic branch, so every accepted
    /// sibling it depends on must have its commits there first. The accept's merge can still be
    /// running, or have failed; git, not the landing, says whether the commit is there.
    private func requireDependenciesOnEpicBranch(task: BoardTask, epic: Epic, manager: WorktreeManager) async throws {
        let accepted = try tasks.deps(of: task.id)
            .compactMap { try tasks.get($0) }
            .filter { $0.epicId == epic.id && $0.column == .done }
        guard !accepted.isEmpty else { return }
        let ledger = TaskCommitStore(db)
        let wanted = try accepted.map { (id: $0.id, shared: try ledger.shas(taskId: $0.id)) }
        let taskBranch = Self.taskBranchPrefix + task.id
        let epicBranch = epic.branch
        let missing = try await offMain { () -> (id: String, commit: String)? in
            guard try !manager.branchExists(taskBranch) else { return nil }
            for dep in wanted {
                if let commit = try Self.commitMissing(manager, dependencyId: dep.id, shared: dep.shared, from: epicBranch) {
                    return (dep.id, commit)
                }
            }
            return nil
        }
        guard let missing, let dep = accepted.first(where: { $0.id == missing.id }) else { return }
        throw SupervisorError.dependencyNotOnBranch(
            dependencyId: dep.id, title: dep.title, commit: missing.commit, branch: epicBranch, landing: dep.landing
        )
    }

    /// The dependency's branch tip, or the tip the ledger kept when it was reaped, plus any commits
    /// `task_commit` attributes to it on a shared branch — the first of those `branch` lacks.
    private nonisolated static func commitMissing(
        _ manager: WorktreeManager, dependencyId: String, shared: [String], from branch: String
    ) throws -> String? {
        let tip = try manager.refCommit("refs/heads/\(taskBranchPrefix)\(dependencyId)")
            ?? manager.refCommit(TaskBranchLedger.tipRef(taskId: dependencyId))
        for commit in [tip].compactMap({ $0 }) + shared where try manager.commitExists(commit) {
            if try !manager.isMerged(commit: commit, into: "refs/heads/\(branch)") { return commit }
        }
        return nil
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
        /// A worktree still to be created at `worktreePath`, which setup does after `spawn` answers.
        var pending: PendingCheckout?
    }

    /// `git worktree add` runs the repository's `post-checkout` hook, which can outlast an MCP call
    /// many times over (SPEC §3.1).
    private struct PendingCheckout: Sendable {
        var manager: WorktreeManager
        var taskId: String
        var name: String
        var branch: String
        /// Nil checks out `branch` as it stands, as the epic integrator's worktree does.
        var base: String?
    }

    /// Carries out the placement. A `shared` one that git will not accept — a dirty checkout, or a
    /// branch another worktree holds — degrades to a worktree with a notice rather than failing the
    /// spawn.
    private func checkoutSite(
        project: Project, taskId: String, placement: WorkerPlacement, base: String,
        cutsFromProjectBase: Bool, manager: WorktreeManager, warnings: [String]
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
        // SPEC §3.1 step 1: a reused task branch keeps whatever it was cut from.
        let start = try await offMain { () -> BaseStartPoint in
            guard cutsFromProjectBase, try !manager.branchExists(branch) else { return BaseStartPoint(ref: base) }
            return manager.freshestBase(base)
        }
        if let warning = start.warning { report([warning]) }
        let worktree = manager.worktreeRoot.appendingPathComponent(taskId)
        return CheckoutSite(
            placement: .worktree, cwd: worktree, worktreePath: worktree.path, branch: branch,
            warnings: fallbackWarnings + [start.warning].compactMap { $0 },
            pending: PendingCheckout(manager: manager, taskId: taskId, name: taskId, branch: branch, base: start.ref)
        )
    }

    private func createWorktree(_ pending: PendingCheckout) async throws {
        // SPEC §5: a worktree a reap or teardown has claimed is about to be deleted, so it is not reused.
        await awaitTeardown(of: pending.manager.worktreeRoot.appendingPathComponent(pending.name).path)
        // A reviewer creates its worktree before any session row exists, so a discard cannot cancel it.
        // `tasks.get` is allowed to throw here — a read failure is reported as itself, not folded
        // into "discarded" just because both read as "no task came back."
        guard !discarding.contains(pending.taskId), try tasks.get(pending.taskId) != nil else {
            throw SupervisorError.taskBeingDiscarded(taskId: pending.taskId)
        }
        await beforeCheckoutCreated()
        try _Concurrency.Task.checkCancellation()
        try await offMain {
            guard try Self.existingWorktree(pending.manager, name: pending.name) == nil else { return }
            if let base = pending.base {
                _ = try pending.manager.create(name: pending.name, branch: pending.branch, base: base)
            } else {
                _ = try pending.manager.createForBranch(name: pending.name, branch: pending.branch)
            }
        }
    }

    /// A shared placement creates no path, so a warning left over from an earlier spawn would be
    /// read as this one's.
    private func clearedWorktreePathWarning() -> [String] {
        lastWorktreePathWarning = nil
        return []
    }

    private static func setupRow(
        projectId: String, taskId: String, site: CheckoutSite, attempt: Int,
        rosterAgentId: String? = nil, reviewHead: String? = nil, reviewBase: String? = nil
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
            reviewHead: reviewHead,
            reviewBase: reviewBase
        )
    }

    /// The failure has nowhere to be thrown once `spawn` has answered, so it reaches the
    /// orchestrator the way every other asynchronous worker outcome does: as a queued report, with
    /// the task put back in `ready` rather than left in `running` behind a session that never ran.
    /// `placingMark` is released once setup ends, not when `spawn` answers, so no retry adopts the
    /// worktree while this attempt's hook or its rollback is still running in it (SPEC §3.1). A cancelled
    /// setup is ended by whoever cancelled it; if that happened before setup ended, its end queues a
    /// report of its own, since a retry refused meanwhile has no other cue.
    private func beginSetup(
        _ plan: LaunchPlan, placeholder: AgentSession, port: Int,
        checkout: PendingCheckout? = nil, placingMark: String? = nil
    ) {
        let sessionId = placeholder.sessionId
        setupTasks[sessionId] = _Concurrency.Task { [weak self] in
            guard let self else { return }
            do {
                if let checkout {
                    try await createWorktree(checkout)
                    await afterCheckoutCreated()
                    try _Concurrency.Task.checkCancellation()
                }
                _ = try await launch(plan, port: port, placeholder: placeholder)
            } catch where !_Concurrency.Task.isCancelled {
                lastError = describe(error)
                // The placeholder may already have been resolved into a real session, in which case
                // that is the row to end — the placeholder no longer exists to be reported against.
                let live = ((try? sessions.forTask(plan.taskId)) ?? [])
                    .first { $0.state.isActive }?.sessionId ?? sessionId
                failSetup(sessionId: live, projectId: plan.project.id, error: error)
            } catch {}
            if let placingMark { placing.remove(placingMark) }
            if _Concurrency.Task.isCancelled, !discarding.contains(plan.taskId),
               (try? sessions.get(sessionId))?.state.isActive == false {
                reportSetupEnded(plan, sessionId: sessionId)
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
        let queued = (try? terminateSession(sessionId, cause: .setupFailed(detail))) ?? nil
        guard queued != nil else { return }
        announceReports(projectId: projectId)
        // `sessionId` always names a real row (`assign` writes it before setup runs), so this could
        // route to `.session(sessionId)` the way the stall and cap banners do. It stays on `.project`
        // because the Status row it would land on carries no diagnosis — no transcript, no spend, a
        // bare `failed` state — while `detail` is the actual worktree-prep failure, which only the
        // queued report on the Orchestrator screen shows.
        post("Worker never started", body: detail, projectId: projectId, category: .workerFailures)
    }

    private func reportSetupEnded(_ plan: LaunchPlan, sessionId: String) {
        guard let task = try? tasks.get(plan.taskId) else { return }
        let lines = [
            "Setup ended for an attempt that was stopped while it set up",
            "Task: \(task.id) (\(task.title))",
            "Session: \(sessionId) (attempt \(plan.attempt))",
            "Nothing is setting up this task any more, so a spawn refused with \"still setting up\" can be sent again.",
        ]
        _ = try? ReportStore(db).insert(
            projectId: plan.project.id, taskId: task.id, sessionId: nil, kind: .decision,
            body: lines.joined(separator: "\n")
        )
        announceReports(projectId: plan.project.id)
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

    /// SPEC §8.2: a crash leaves the Coordinator's row live with no PTY behind it, where it would be
    /// metered every tick and read as running.
    private func stopOrphanedCoordinatorSessions() {
        guard coordinatorConsoleInstance?.isProcessRunning != true else { return }
        for session in (try? coordinator.sessions()) ?? [] where session.state.isActive {
            _ = try? terminateSession(session.sessionId, cause: .vanished)
        }
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
        var extraDisallowedTools: [String] = []
    }

    /// `claude` is spawned without a shell, so nothing else would expand a `~` the user typed.
    private func expandingHome(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return home.path + path.dropFirst()
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
                fileLocks: plan.worktreePath == nil,
                readOnly: plan.scope == .triager
            )
            let request = SpawnRequest(
                cwd: plan.cwd,
                name: plan.name,
                prompt: plan.prompt,
                configFiles: configFiles,
                // A deny-list, layered on: a rostered agent can only ever have less authority than a
                // plain worker, and an empty list is exactly a plain worker's.
                disallowedTools: Self.disallowedTools(scope: plan.scope, supportDir: appSupportDir, home: home)
                    + plan.extraDisallowedTools + (plan.rosterAgent?.disallowedTools ?? []),
                tools: plan.rosterAgent?.tools,
                model: plan.model,
                pluginDirs: (plan.rosterAgent?.pluginDirs ?? []).map(expandingHome)
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

    nonisolated static func disallowedTools(scope: AgentBoardCore.TokenScope, supportDir: URL, home: URL) -> [String] {
        switch scope {
        case .reviewer:
            return SpawnRequest.defaultDisallowedTools + SpawnRequest.reviewerDisallowedTools
                + SpawnRequest.reviewerBoardDeny(supportDir: supportDir, home: home)
        case .triager:
            return SpawnRequest.triagerDisallowedTools
                + SpawnRequest.reviewerBoardDeny(supportDir: supportDir, home: home)
        case .worker, .orchestrator, .coordinator:
            return SpawnRequest.defaultDisallowedTools
        }
    }

    /// SPEC §13.2. The triager is an ordinary worker session, so every §8 cap counts it, in a
    /// detached checkout of the PR head fetched from origin, bound to a synthetic `triage` task so its
    /// card and progress log are real. Nothing but the supervisor calls this.
    @discardableResult
    func spawnTriager(watchId: String) async throws -> AgentSession {
        guard let watch = try prWatches.get(watchId) else { throw SupervisorError.watchNotFound(watchId) }
        guard let project = try projects.get(watch.projectId) else {
            throw SupervisorError.projectNotFound(watch.projectId)
        }
        guard let port = serverPort else { throw SupervisorError.serverNotRunning }
        try requireNoShutdown(projectId: project.id)
        if case .refused(let reason) = try CapCheck(db).canSpawn(projectId: project.id) {
            throw SupervisorError.capRefused(reason)
        }
        let role = project.settings.prFollowThrough.roles.triage
        let agent = try role?.rosterAgentId.map { id -> RosterAgent in
            guard let agent = try roster.usableAgent(id, forProject: project.id) else {
                throw SupervisorError.rosterAgentNotUsable(id: id, projectName: project.name)
            }
            return agent
        }

        let manager = worktreeManager(for: project)
        let headOid = watch.headOid
        let baseRef = watch.baseRef
        let baseOid: String
        do {
            baseOid = try await offMain { () -> String in
                guard try manager.fetchCommitIfMissing(headOid, from: "origin") else {
                    throw AgentRuntimeError("origin has no commit \(headOid)")
                }
                return try manager.fetchRemoteTip(baseRef)
            }
        } catch {
            throw SupervisorError.pullRequestNotFetched(describe(error))
        }

        let task = try board.createTriageTask(watchId: watch.id, baseOid: baseOid, headOid: headOid)
        let triage = PRTriage(
            taskId: task.id, watchId: watch.id, baseOid: baseOid, headOid: headOid, round: watch.round,
            createdAt: task.createdAt
        )
        _ = preflightWorktreePath(manager.worktreeRoot.appendingPathComponent(task.id))
        var assigned: AgentSession?
        do {
            let worktree = try await offMain { try manager.createDetached(name: task.id, commit: headOid) }
            let placeholder = try board.assign(
                taskId: task.id,
                session: AgentSession(
                    sessionId: "setup-\(UUID().uuidString)", projectId: project.id, taskId: task.id, role: .worker,
                    worktreePath: worktree.path, cwd: worktree.path, state: .setup, attempt: 1,
                    rosterAgentId: agent?.id
                )
            )
            assigned = placeholder
            beginSetup(
                LaunchPlan(
                    project: project,
                    taskId: task.id,
                    cwd: worktree,
                    worktreePath: worktree.path,
                    branch: headOid,
                    configId: Self.configId(taskId: task.id, attempt: placeholder.attempt),
                    name: Self.sessionName(for: task),
                    prompt: TriagePrompt.compose(
                        watch: watch, triage: triage, workingDirectory: worktree.path, agent: agent?.identity
                    ),
                    model: role?.model ?? agent?.model ?? project.settings.defaultModel,
                    attempt: placeholder.attempt,
                    rosterAgent: agent,
                    scope: .triager
                ),
                placeholder: placeholder,
                port: port
            )
            return placeholder
        } catch {
            if assigned == nil { try? tasks.delete(task.id) }
            throw SupervisorError.spawnFailed(
                worktree: manager.worktreeRoot.appendingPathComponent(task.id).path, underlying: describe(error)
            )
        }
    }

    /// SPEC §13.1 fixing: an ordinary worker on the round's branch, cut at the head its triage read
    /// once the PR's head ref is fetched from origin, in a worktree named for the task. A retry reuses
    /// both. The role's roster agent and model apply unless the caller names an agent.
    private func spawnFixer(
        task: BoardTask, rosterAgentId: String?, project: Project, port: Int
    ) async throws -> WorkerSpawn {
        guard let round = try prWatches.round(fixTaskId: task.id), let watch = try prWatches.get(round.watchId) else {
            throw SupervisorError.fixRoundNotFound(title: task.title)
        }
        let role = project.settings.prFollowThrough.roles.fixer
        let agent = try (rosterAgentId ?? role?.rosterAgentId).map { id -> RosterAgent in
            guard let agent = try roster.usableAgent(id, forProject: project.id) else {
                throw SupervisorError.rosterAgentNotUsable(id: id, projectName: project.name)
            }
            return agent
        }
        if let holder = try sessions.activeHolder(taskId: task.id) {
            throw SupervisorError.taskAlreadyHeld(title: task.title, sessionId: holder.sessionId)
        }

        let manager = worktreeManager(for: project)
        let headRef = watch.headRef
        let baseHeadOid = round.baseHeadOid
        do {
            try await offMain {
                _ = try manager.fetchRemoteTip(headRef)
                guard try manager.fetchCommitIfMissing(baseHeadOid, from: "origin") else {
                    throw AgentRuntimeError("origin has no commit \(baseHeadOid)")
                }
            }
        } catch {
            throw SupervisorError.pullRequestNotFetched(describe(error))
        }

        let name = task.id
        let branch = PRRound.branch(pullRequest: watch.number, round: round.number)
        let warnings = preflightWorktreePath(manager.worktreeRoot.appendingPathComponent(name))
        let worktree: URL
        do {
            worktree = try await offMain {
                try Self.existingWorktree(manager, name: name)
                    ?? manager.create(name: name, branch: branch, base: baseHeadOid)
            }
        } catch {
            throw SupervisorError.spawnFailed(
                worktree: manager.worktreeRoot.appendingPathComponent(name).path, underlying: describe(error)
            )
        }
        if let holder = try sessions.activeHolder(worktreePath: worktree.path) {
            throw SupervisorError.worktreeAlreadyHeld(path: worktree.path, sessionId: holder.sessionId)
        }

        do {
            let site = CheckoutSite(
                placement: .worktree, cwd: worktree, worktreePath: worktree.path, branch: branch, warnings: warnings
            )
            let placeholder = try board.assign(
                taskId: task.id,
                session: Self.setupRow(
                    projectId: project.id, taskId: task.id, site: site,
                    attempt: try sessions.forTask(task.id).count + 1, rosterAgentId: agent?.id
                )
            )
            beginSetup(
                LaunchPlan(
                    project: project,
                    taskId: task.id,
                    cwd: worktree,
                    worktreePath: worktree.path,
                    branch: branch,
                    configId: Self.configId(taskId: task.id, attempt: placeholder.attempt),
                    name: Self.sessionName(for: task),
                    prompt: Self.openingPrompt(
                        task: task, branch: branch, attempt: placeholder.attempt, epicGoal: nil,
                        notes: try notes.notesForSpawn(projectId: project.id, taskId: task.id, epicId: nil),
                        verification: project.settings.verification,
                        placement: .worktree,
                        workingDirectory: worktree.path,
                        agent: agent?.identity,
                        reviewFindings: try ProgressStore(db).openReviewFindings(taskId: task.id),
                        comments: try CommentStore(db).list(taskId: task.id)
                    ),
                    model: task.model ?? agent?.model ?? project.settings.defaultModel,
                    attempt: placeholder.attempt,
                    rosterAgent: agent,
                    extraDisallowedTools: SpawnRequest.fixerDisallowedTools
                ),
                placeholder: placeholder,
                port: port
            )
            return WorkerSpawn(
                setupSessionId: placeholder.sessionId, worktreePath: worktree.path, branch: branch,
                sharesCheckout: false, warnings: warnings
            )
        } catch {
            throw SupervisorError.spawnFailed(worktree: worktree.path, underlying: describe(error))
        }
    }

    /// SPEC §13.1 checking: a round's reviewer reads `base_head_oid...HEAD` on the round branch, in the
    /// fixer's own worktree, never a task branch against the project's base. A branch with nothing on it
    /// beyond the pull request's head is a round that fixed nothing.
    private func spawnRoundReviewer(
        task: BoardTask, rosterAgentId: String, project: Project, port: Int
    ) async throws -> WorkerSpawn {
        guard let round = try prWatches.round(fixTaskId: task.id), let watch = try prWatches.get(round.watchId) else {
            throw SupervisorError.fixRoundNotFound(title: task.title)
        }
        guard let agent = try roster.usableAgent(rosterAgentId, forProject: project.id) else {
            throw SupervisorError.rosterAgentNotUsable(id: rosterAgentId, projectName: project.name)
        }
        if let holder = try sessions.activeHolder(taskId: task.id) {
            throw SupervisorError.taskAlreadyHeld(title: task.title, sessionId: holder.sessionId)
        }
        let manager = worktreeManager(for: project)
        let name = task.id
        guard let worktree = try await offMain({ try Self.existingWorktree(manager, name: name) }) else {
            throw SupervisorError.spawnFailed(
                worktree: manager.worktreeRoot.appendingPathComponent(name).path,
                underlying: "the round's worktree is gone, so there is nothing to review"
            )
        }
        if let holder = try sessions.activeHolder(worktreePath: worktree.path) {
            throw SupervisorError.worktreeAlreadyHeld(path: worktree.path, sessionId: holder.sessionId)
        }
        let branch = PRRound.branch(pullRequest: watch.number, round: round.number)
        let base = round.baseHeadOid
        guard try await offMain({ try ReviewCheckout.hasDiff(against: base, in: worktree) }) else {
            throw NothingToReview(reason: "Branch `\(branch)` has no change beyond the pull request's head `\(base)`, "
                + "so the round fixed nothing.")
        }

        do {
            let reviewHead = try await offMain { try ReviewCheckout.baseline(in: worktree) }
            let site = CheckoutSite(placement: .worktree, cwd: worktree, worktreePath: worktree.path, branch: branch, warnings: [])
            let placeholder = try board.assignReviewer(
                taskId: task.id,
                session: Self.setupRow(
                    projectId: project.id, taskId: task.id, site: site, attempt: try sessions.forTask(task.id).count + 1,
                    rosterAgentId: agent.id, reviewHead: reviewHead, reviewBase: base
                )
            )
            let role = project.settings.prFollowThrough.roles.reviewer
            beginSetup(
                LaunchPlan(
                    project: project,
                    taskId: task.id,
                    cwd: worktree,
                    worktreePath: worktree.path,
                    branch: branch,
                    configId: Self.configId(taskId: task.id, attempt: placeholder.attempt),
                    name: Self.sessionName(for: task),
                    prompt: ReviewPrompt.compose(
                        task: task, branch: branch, base: base, verification: project.settings.verification,
                        workingDirectory: worktree.path, agent: agent.identity,
                        comments: try CommentStore(db).list(taskId: task.id)
                    ),
                    model: role?.model ?? agent.model ?? project.settings.defaultModel,
                    attempt: placeholder.attempt,
                    rosterAgent: agent,
                    scope: .reviewer
                ),
                placeholder: placeholder,
                port: port
            )
            return WorkerSpawn(
                setupSessionId: placeholder.sessionId, worktreePath: worktree.path, branch: branch,
                sharesCheckout: false, warnings: []
            )
        } catch {
            throw SupervisorError.spawnFailed(worktree: worktree.path, underlying: describe(error))
        }
    }

    /// SPEC §13.1 checking: the follow-up checker holds a triager grant, so it reads and grades and
    /// changes nothing, in a detached checkout of the round branch's tip, bound to a synthetic
    /// `followup_check` task. `roles.followupCheck` picks the roster agent, whose plugin dirs it runs with.
    private func spawnFollowupCheck(_ watch: PRWatch, round: PRRound, project: Project) async throws {
        guard let port = serverPort else { throw SupervisorError.serverNotRunning }
        try requireNoShutdown(projectId: project.id)
        if case .refused(let reason) = try CapCheck(db).canSpawn(projectId: project.id) {
            throw SupervisorError.capRefused(reason)
        }
        let role = project.settings.prFollowThrough.roles.followupCheck
        let agent = try role?.rosterAgentId.map { id -> RosterAgent in
            guard let agent = try roster.usableAgent(id, forProject: project.id) else {
                throw SupervisorError.rosterAgentNotUsable(id: id, projectName: project.name)
            }
            return agent
        }
        let manager = worktreeManager(for: project)
        let branch = PRRound.branch(pullRequest: watch.number, round: round.number)
        guard let headOid = try await offMain({ try manager.refCommit("refs/heads/\(branch)") }) else {
            throw AgentRuntimeError("the round branch `\(branch)` does not exist")
        }
        guard let task = try board.createFollowupCheckTask(watchId: watch.id, headOid: headOid) else { return }
        _ = preflightWorktreePath(manager.worktreeRoot.appendingPathComponent(task.id))
        var assigned: AgentSession?
        do {
            let worktree = try await offMain { try manager.createDetached(name: task.id, commit: headOid) }
            let placeholder = try board.assign(
                taskId: task.id,
                session: AgentSession(
                    sessionId: "setup-\(UUID().uuidString)", projectId: project.id, taskId: task.id, role: .worker,
                    worktreePath: worktree.path, cwd: worktree.path, state: .setup, attempt: 1,
                    rosterAgentId: agent?.id
                )
            )
            assigned = placeholder
            beginSetup(
                LaunchPlan(
                    project: project,
                    taskId: task.id,
                    cwd: worktree,
                    worktreePath: worktree.path,
                    branch: headOid,
                    configId: Self.configId(taskId: task.id, attempt: placeholder.attempt),
                    name: Self.sessionName(for: task),
                    prompt: FollowupCheckPrompt.compose(
                        watch: watch, round: round, headOid: headOid, workingDirectory: worktree.path,
                        agent: agent?.identity
                    ),
                    model: role?.model ?? agent?.model ?? project.settings.defaultModel,
                    attempt: placeholder.attempt,
                    rosterAgent: agent,
                    scope: .triager
                ),
                placeholder: placeholder,
                port: port
            )
        } catch {
            if assigned == nil { try? tasks.delete(task.id) }
            throw SupervisorError.spawnFailed(
                worktree: manager.worktreeRoot.appendingPathComponent(task.id).path, underlying: describe(error)
            )
        }
    }

    /// §5.2 step 3. The integrator is an ordinary worker on a worktree checked out on the epic
    /// branch, bound to a synthetic task so its token scope, report channel and board card are real.
    /// `retrying` is an earlier integration task of this epic, respawned instead of creating another.
    @discardableResult
    private func spawnIntegrator(epicId: String, retrying existing: BoardTask? = nil) async throws -> AgentSession {
        guard let epic = try epics.get(epicId) else { throw SupervisorError.epicNotFound(epicId) }
        guard let project = try projects.get(epic.projectId) else {
            throw SupervisorError.projectNotFound(epic.projectId)
        }
        guard let port = serverPort else { throw SupervisorError.serverNotRunning }
        try requireNoShutdown(projectId: project.id)
        if case .refused(let reason) = try CapCheck(db).canSpawn(projectId: project.id) {
            throw SupervisorError.capRefused(reason)
        }
        let shipsByPullRequest = try await standaloneIntegration(of: project) == .pullRequest

        let manager = worktreeManager(for: project)
        let worktreeName = HeldWorktree.epicWorktreeName(epicId: epicId)
        let worktree = manager.worktreeRoot.appendingPathComponent(worktreeName)
        _ = preflightWorktreePath(worktree)
        let epicBranch = epic.branch
        // SPEC §3.1: the epic worktree is created in setup, after this answers, like any task's.
        guard !placing.contains(worktree.path) else {
            throw SupervisorError.setupStillRunning(title: existing?.title ?? epic.title, path: worktree.path)
        }
        if let holder = try sessions.activeHolder(worktreePath: worktree.path) {
            throw SupervisorError.worktreeAlreadyHeld(path: worktree.path, sessionId: holder.sessionId)
        }
        placing.insert(worktree.path)
        var setupHoldsMark = false
        defer { if !setupHoldsMark { placing.remove(worktree.path) } }

        let members = try tasks.list(projectId: project.id, epicId: epicId, includeArchived: true)
            .filter { $0.origin != .integration && $0.column != .closed }
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
            guard try manager.branchExists(epicBranch) else {
                throw AgentRuntimeError("epic branch \(epicBranch) does not exist in \(manager.repoPath.path)")
            }
            let merged = try manager.mergeStatus(into: "refs/heads/\(epicBranch)", branches: branchNames)
            return try Self.branchFacts(
                manager, taskIds: taskIds, epicBranch: epicBranch, baseBranch: projectBase,
                sharedBranches: shared, merged: merged, dispatched: dispatched
            )
        }
        let branches = IntegrationPlan.classify(ordered, facts: facts)

        if let existing, let holder = try sessions.activeHolder(taskId: existing.id) {
            throw SupervisorError.taskAlreadyHeld(title: existing.title, sessionId: holder.sessionId)
        }
        let task = try existing ?? board.createIntegrationTask(epicId: epicId)
        let attempt = try sessions.forTask(task.id).count + 1
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
                    attempt: attempt
                )
            )
            assigned = placeholder
            try epics.setShipsByPullRequest(epicId, shipsByPullRequest)
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
                port: port,
                checkout: PendingCheckout(
                    manager: manager, taskId: task.id, name: worktreeName, branch: epicBranch, base: nil
                ),
                placingMark: worktree.path
            )
            setupHoldsMark = true
            return placeholder
        } catch {
            // A task with a session row on it cannot be deleted; the failure path below owns it.
            if assigned == nil, existing == nil { try? tasks.delete(task.id) }
            throw SupervisorError.spawnFailed(worktree: worktree.path, underlying: describe(error))
        }
    }

    func stop(sessionId: String) async throws {
        try await recording { try await stopSession(sessionId, by: .human) }
    }

    private func stopSession(_ sessionId: String, by actor: BoardActor) async throws {
        let session = try requireSession(sessionId)
        if let shortId = session.shortId {
            try await stopAgent(session, shortId: shortId)
        } else if session.state == .setup {
            // No agent to stop yet; `launch` finds the row gone and stops whatever it started.
            setupTasks[sessionId]?.cancel()
        } else {
            throw SupervisorError.sessionHasNoShortId(sessionId)
        }
        let salvage = await branchSalvage(taskId: session.taskId)
        try terminateSession(sessionId, cause: .stopped(by: actor), salvage: salvage)
        try grants.revokeAll(sessionId: sessionId)
        announceReports(projectId: session.projectId)
        refreshSleepAssertion()
    }

    /// SPEC §8.5: no process a session started outlives it. The host's tree is read before
    /// `claude stop`, which leaves a `run_in_background` command running under launchd.
    private func stopAgent(_ session: AgentSession, shortId: String, listing: [AgentInfo]? = nil) async throws {
        let listed = await listingOrFetch(listing)
        var tree: Set<PIDIdentity> = []
        if let host = Self.hostPID(of: session, in: listed) { tree = await SessionProcessReaper.tree(ofHost: host) }
        do {
            try await runtime.stop(shortId: shortId)
        } catch {
            await reapProcesses(of: session, tree: tree, listing: listed)
            throw error
        }
        try? sessions.markAgentStopped(session.sessionId)
        await reapProcesses(of: session, tree: tree, listing: listed)
    }

    /// SPEC §8.5. The worktree rule is off for a shared checkout, and while another live session
    /// shares the worktree, since an orphan there could be that session's.
    private func reapProcesses(
        of session: AgentSession, tree: Set<PIDIdentity> = [], listing: [AgentInfo]? = nil
    ) async {
        let listed = await listingOrFetch(listing)
        let host = Self.hostPID(of: session, in: listed)
        let shared = session.worktreePath.map { path in
            ((try? sessions.all(projectId: session.projectId)) ?? []).contains {
                $0.sessionId != session.sessionId && $0.state.isActive && $0.worktreePath == path
            }
        } ?? true
        let scope = SessionProcessScope(
            tree: tree,
            worktree: shared ? nil : session.worktreePath,
            startedAtMicros: session.startedAt * 1000,
            otherHosts: Set(listed.compactMap { $0.pid.map { pid_t($0) } }.filter { $0 != host })
        )
        await SessionProcessReaper.reap(scope)
    }

    private func listingOrFetch(_ listing: [AgentInfo]?) async -> [AgentInfo] {
        if let listing { return listing }
        return (try? await runtime.listSessions()) ?? []
    }

    private static func hostPID(of session: AgentSession, in listing: [AgentInfo]) -> pid_t? {
        listing.first { info in
            info.sessionId == session.sessionId || (session.shortId != nil && info.id == session.shortId)
        }?.pid.map { pid_t($0) }
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
            // SPEC §5: until the row is active again only this mark keeps a reap out of the worktree.
            if let path = session.worktreePath {
                if tearingDown.contains(Self.resolved(path)) { throw SupervisorError.worktreeBeingRemoved(path: path) }
                if placing.contains(path) {
                    let title = (try? session.taskId.flatMap { try tasks.get($0) })?.title ?? path
                    throw SupervisorError.setupStillRunning(title: title, path: path)
                }
                placing.insert(path)
            }
            defer { if let path = session.worktreePath { placing.remove(path) } }
            resuming.insert(sessionId)
            defer { resuming.remove(sessionId) }
            guard let port = serverPort else { throw SupervisorError.serverNotRunning }
            guard let taskId = session.taskId else { throw SupervisorError.taskNotFound("(none for session \(sessionId))") }
            guard let project = try projects.get(session.projectId) else {
                throw SupervisorError.projectNotFound(session.projectId)
            }
            // SPEC §13.2: the grant and config below are a worker's, and a triage is cheap to start over.
            if let task = try tasks.get(taskId), task.origin.isPullRequestReader {
                throw SupervisorError.triageNotResumable(title: task.title)
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
                        try await stopAgent(session, shortId: shortId)
                    } else if session.state == .setup {
                        setupTasks[session.sessionId]?.cancel()
                    } else {
                        throw SupervisorError.sessionHasNoShortId(session.sessionId)
                    }
                    try terminateSession(session.sessionId, cause: .stopped(by: .human))
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
        try await accept(taskId: taskId, acceptedBy: .human, landsAfterReturning: false)
    }

    /// The accept a tool call makes. Landing a shared branch runs the repository's `post-checkout`
    /// hook and teardown runs `WorktreeRemove` hooks, so both finish after the caller has its answer (SPEC §6).
    func accept(taskId: String, acceptedBy: TaskAcceptance) async throws {
        try await accept(taskId: taskId, acceptedBy: acceptedBy, landsAfterReturning: true)
    }

    private func accept(taskId: String, acceptedBy: TaskAcceptance, landsAfterReturning: Bool) async throws {
        try await recording {
            guard let task = try tasks.get(taskId) else { throw SupervisorError.taskNotFound(taskId) }
            guard let project = try projects.get(task.projectId) else {
                throw SupervisorError.projectNotFound(task.projectId)
            }
            // SPEC §13.1: a round's branch is pushed onto its pull request, never merged as a task branch.
            if task.origin == .fixRound { throw SupervisorError.fixRoundNotAcceptable(title: task.title) }
            try await stopLiveSessions(onTask: taskId, sparing: acceptedBy.acceptingSessionId, by: acceptedBy.actor)
            try board.accept(taskId: taskId, acceptedBy: acceptedBy)
            let acceptanceReport = try? ReportStore(db).latest(taskId: taskId)?.id
            let taskSessions = try sessions.forTask(taskId)
            for session in taskSessions {
                try grants.revokeAll(sessionId: session.sessionId)
                try fileLocks.releaseAll(sessionId: session.sessionId)
            }
            // Claimed now, so no reap takes the worktree for an orphan while the landing runs (SPEC §5).
            let claim = claimTeardown(of: taskSessions)
            let settle: @MainActor (WorkerSupervisor) async -> Void = { supervisor in
                await supervisor.landAndTearDown(task: task, project: project, claim: claim, report: acceptanceReport)
            }
            if landsAfterReturning {
                inBackground(settle)
            } else {
                await settle(self)
            }
        }
    }

    private func landAndTearDown(task: BoardTask, project: Project, claim: TeardownClaim, report: Int64?) async {
        // SPEC §5: a task branch lands before its worktree is removed, which can take a minute
        // on a large repository while a dependent cut from the target lacks this work. A shared
        // branch has no worktree to wait on and lands only once every member is accepted.
        if sharedBranch(of: task) != nil {
            await startTeardown(claim, task: task, project: project, report: report, landingNotice: nil)
            await landAcceptedBranch(task: task, project: project)
        } else {
            let before = lastError
            await landAcceptedBranch(task: task, project: project)
            let landingNotice = lastError == before ? nil : lastError
            await startTeardown(claim, task: task, project: project, report: report, landingNotice: landingNotice)
        }
        announceReports(projectId: task.projectId)
    }

    /// A teardown hook may run for minutes, and an accept may be answering an MCP call, so behind a
    /// hook the teardown runs after the caller returns. `claim` is taken before this is called, so a
    /// reconcile scheduled ahead of the background task already sees those worktrees as taken.
    private func startTeardown(
        _ claim: TeardownClaim, task: BoardTask, project: Project, report reportId: Int64?, landingNotice: String?
    ) async {
        guard project.settings.worktreeTeardown != nil else {
            await finishTeardown(claim, task: task, project: project, report: reportId, landingNotice: landingNotice)
            return
        }
        inBackground { supervisor in
            if await supervisor.finishTeardown(
                claim, task: task, project: project, report: reportId, landingNotice: landingNotice
            ) {
                supervisor.announceReports(projectId: task.projectId)
            }
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
                    try terminateSession(session.sessionId, cause: .vanished, salvage: salvage)
                    await reapProcesses(of: session, listing: listing)
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

    /// True when it wrote a report the orchestrator has to be told about.
    @discardableResult
    private func finishTeardown(
        _ claim: TeardownClaim, task: BoardTask, project: Project, report reportId: Int64?, landingNotice: String?
    ) async -> Bool {
        let cleanup = await tearDownWorktrees(claim, task: task, project: project)
        if !cleanup.notices.isEmpty { report([landingNotice].compactMap { $0 } + cleanup.notices) }
        let findings = cleanup.findings.map(\.text)
        return (try? board.recordWorktreeCleanup(taskId: task.id, reportId: reportId, findings: findings)) ?? false
    }

    /// Waits for teardowns still running behind a teardown hook, and for the landing of an accept
    /// a tool call made.
    func waitForTeardowns() async {
        while let task = teardownTasks.values.first {
            await task.value
        }
    }

    private func inBackground(_ body: @escaping @MainActor (WorkerSupervisor) async -> Void) {
        let id = UUID()
        teardownTasks[id] = _Concurrency.Task { [weak self] in
            guard let self else { return }
            await body(self)
            teardownTasks[id] = nil
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

    /// SPEC §5: the stored choice, else what `origin` resolves to. A git failure keeps this project's
    /// last resolved answer and, with none, throws rather than guess local merge.
    private func standaloneIntegration(of project: Project) async throws -> StandaloneIntegration {
        if let stored = project.settings.standaloneIntegration { return stored }
        let publisher = BranchPublisher(repoPath: URL(fileURLWithPath: project.repoPath))
        do {
            let resolved = try await offMain { try publisher.defaultStandaloneIntegration() }
            integrationDefaults[project.id] = resolved
            return resolved
        } catch {
            guard let previous = integrationDefaults[project.id] else { throw error }
            return previous
        }
    }

    private func mergeTaskBranch(task: BoardTask, epic: Epic?, project: Project, into target: String) async {
        let manager = worktreeManager(for: project)
        let taskBranch = Self.taskBranchPrefix + task.id
        let taskTitle = task.title
        let targetTitle = epic?.title ?? project.baseBranch
        let projectBase = project.baseBranch
        let epicBranch = epic?.branch
        var byPullRequest = false
        if epic == nil {
            do {
                byPullRequest = try await standaloneIntegration(of: project) == .pullRequest
            } catch {
                recordLanding(
                    task: task, epic: epic, landing: .unlanded,
                    detail: "`\(taskBranch)` was not merged into `\(target)`: Agent Board could not read the "
                        + "project's origin remote to choose between pull request and local merge. \(describe(error))",
                    advice: "Merge `\(taskBranch)` into `\(target)` by hand or open a pull request for it, and "
                        + "choose an integration in the project's Publishing settings so the next accept need not ask git."
                )
                return
            }
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
                    taskTitle: taskTitle, targetTitle: targetTitle
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
            // No branch is two different facts: a sweep deletes a task branch whose work some other
            // hand already merged, so "gone" can mean landed, and the ledger tip ref, which outlives
            // the branch, tells the two apart. Either way this accept merged nothing, so it says so.
            let reaped = (try? await offMain {
                try manager.refCommit(TaskBranchLedger.tipRef(taskId: task.id)).map {
                    (tip: $0, merged: try manager.isMerged(commit: $0, into: "refs/heads/\(target)"))
                }
            }) ?? nil
            switch reaped {
            case .none:
                recordLanding(
                    task: task, epic: epic, landing: .noBranch,
                    detail: "`\(taskBranch)` does not exist, so nothing was merged into `\(target)`.",
                    advice: nil, reportAlways: true
                )
            case .some(let reaped) where reaped.merged:
                recordLanding(
                    task: task, epic: epic, landing: .landed,
                    detail: "`\(taskBranch)` was already deleted when the accept ran, so it merged nothing; "
                        + "`\(target)` contains its last commit, \(reaped.tip).",
                    advice: nil, reportAlways: true
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

    /// SPEC §13.1: watches the user's open, non-draft pull requests in every project with PR
    /// follow-through on, mapping each repository to the project whose `origin` names it, then
    /// advances each watch through settling and triaging. No project enabled means no `gh` call at all.
    /// A call made while a poll runs waits for it and then polls again, so it always reads state
    /// written before the call.
    func pollPRWatches() async {
        while let inFlight = prWatchPoll { await inFlight.value }
        let poll = _Concurrency.Task {
            await runPRWatchPoll()
            prWatchPoll = nil
        }
        prWatchPoll = poll
        await poll.value
    }

    private func runPRWatchPoll() async {
        let enabled = ((try? projects.list()) ?? []).filter { $0.settings.prFollowThrough.enabled }
        guard !enabled.isEmpty else {
            try? prWatches.setPollProblems([:])
            return
        }
        await refreshPRWatches(enabled)
        await advancePRWatches(enabled)
    }

    /// Writes each poll through `PRWatchStore` and moves a watch among watching, settling,
    /// readyToVerify and verified, bannering a PR's arrival in readyToVerify once per head oid
    /// (§13.4); a watch whose PR left the open list settles to merged or closed by `gh pr view`,
    /// and one whose PR went back to draft is deleted.
    private func refreshPRWatches(_ enabled: [Project]) async {
        var projectByRepo: [String: Project] = [:]
        var problems: [String: String] = [:]
        for project in enabled {
            let repo = URL(fileURLWithPath: project.repoPath)
            let remote: String
            do {
                remote = try await offMain { try BranchPublisher(repoPath: repo).requireRemote() }
                prWatchRemoteFailures[project.id] = nil
            } catch PublishFailure.noRemote {
                prWatchRemoteFailures[project.id] = nil
                continue
            } catch {
                let failures = (prWatchRemoteFailures[project.id] ?? 0) + 1
                prWatchRemoteFailures[project.id] = failures
                NSLog("PR watch could not read %@'s origin (%d in a row): %@", project.name, failures, describe(error))
                if failures >= Self.prWatchFailuresBeforeAttention {
                    problems[project.id] = "Reading `origin` has failed \(failures) times in a row: \(describe(error))"
                }
                continue
            }
            guard let slug = PullRequestLaunch.githubSlug(remoteURL: remote)?.lowercased(),
                  projectByRepo[slug] == nil
            else { continue }
            projectByRepo[slug] = project
        }
        guard let anyProject = projectByRepo.values.first else {
            try? prWatches.setPollProblems(problems)
            return
        }

        let reader = pullRequestWatch
        let authored: [AuthoredPullRequest]
        do {
            let cwd = URL(fileURLWithPath: anyProject.repoPath)
            authored = try await offMain { try reader.authored(cwd: cwd) }
            prWatchSearchFailures = 0
            try? prWatches.setPollProblems(problems)
        } catch let failure as PullRequestWatchFailure where failure.ghUnavailable {
            for project in enabled { problems[project.id] = failure.description }
            try? prWatches.setPollProblems(problems)
            return
        } catch {
            prWatchSearchFailures += 1
            NSLog("PR watch poll failed (%d in a row): %@", prWatchSearchFailures, describe(error))
            if prWatchSearchFailures >= Self.prWatchFailuresBeforeAttention {
                for project in enabled {
                    problems[project.id] =
                        "`gh search prs` has failed \(prWatchSearchFailures) times in a row: \(describe(error))"
                }
                try? prWatches.setPollProblems(problems)
            }
            return
        }

        func key(_ repository: String, _ number: Int) -> String { "\(repository.lowercased())#\(number)" }
        let drafts = Set(authored.filter(\.isDraft).map { key($0.repository, $0.number) })
        let open = authored.filter { !$0.isDraft && projectByRepo[$0.repository.lowercased()] != nil }
        let stillOpen = Set(open.map { key($0.repository, $0.number) })
        for (slug, prs) in Dictionary(grouping: open, by: { $0.repository.lowercased() }) {
            guard let project = projectByRepo[slug] else { continue }
            let parts = prs[0].repository.split(separator: "/").map(String.init)
            guard parts.count == 2 else { continue }
            let cwd = URL(fileURLWithPath: project.repoPath)
            let numbers = prs.map(\.number)
            guard let snapshots = try? await offMain({
                try reader.snapshots(owner: parts[0], name: parts[1], numbers: numbers, cwd: cwd)
            }) else { continue }
            for snapshot in snapshots {
                applyPRSnapshot(snapshot, project: project)
            }
        }

        let states = pullRequestStates
        for project in enabled {
            for watch in (try? prWatches.live(projectId: project.id)) ?? [] {
                let watchKey = key("\(watch.repoOwner)/\(watch.repoName)", watch.number)
                if stillOpen.contains(watchKey) { continue }
                if drafts.contains(watchKey) {
                    try? prWatches.delete(watchId: watch.id)
                    continue
                }
                let cwd = URL(fileURLWithPath: project.repoPath)
                let url = watch.url
                switch try? await offMain({ try states.state(of: url, cwd: cwd) }) {
                case .merged: try? prWatches.setState(.merged, watchId: watch.id)
                case .closed: try? prWatches.setState(.closed, watchId: watch.id)
                case .open, nil: break
                }
            }
        }
    }

    private func applyPRSnapshot(_ snapshot: PRSnapshot, project: Project) {
        do {
            var watch = try prWatches.upsert(projectId: project.id, snapshot: snapshot)
            if let settled = try prWatches.settleAwaitingCI(watchId: watch.id) { watch.state = settled }
            let open = try prWatches.openItems(watchId: watch.id)
            if let next = PRWatchTransition.next(
                from: watch, snapshot: snapshot, openItems: open.count,
                itemsAwaitingRound: open.filter { $0.verdict == nil || ($0.verdict == .fix && $0.round > watch.round) }.count,
                settings: project.settings.prFollowThrough
            ) {
                try prWatches.setState(next, watchId: watch.id)
            }
            try prWatches.applyVerifiedFreeze(watchId: watch.id)
            // SPEC §13.4: a paused watch claims its banner without showing it, so resuming replays nothing.
            if let ready = try prWatches.claimReadyNotification(watchId: watch.id), !ready.paused {
                post(
                    "Pull request ready to verify", body: "#\(ready.number) \(ready.title)",
                    projectId: project.id, category: .prReadyToVerify, subject: .pullRequest(ready.id)
                )
            }
        } catch {
            report(["could not record \(snapshot.url): \(describe(error))"])
        }
    }

    /// SPEC §13.1 and §13.2: a settling watch starts one triager per round once no item has arrived
    /// for `settleMinutes` and nothing holds it, a triaging one moves on once that triage ends, a
    /// fixing one starts its round's fixer, a checking one its reviewer and follow-up check, and a
    /// publishing one pushes its round. Then each open decision not yet announced banners once (§13.4).
    private func advancePRWatches(_ enabled: [Project]) async {
        for project in enabled {
            for watch in (try? prWatches.live(projectId: project.id)) ?? [] {
                switch watch.state {
                case .settling: await startTriageIfSettled(watch, project: project)
                case .triaging: await settleTriageRound(watch, project: project)
                case .fixing: await startFixRound(watch, project: project)
                case .checking: await advanceCheck(watch, project: project)
                case .publishing: await publishRound(watch, project: project)
                default: break
                }
                announceDecisions(watchId: watch.id, project: project)
            }
        }
    }

    private func announceDecisions(watchId: String, project: Project) {
        guard let decisions = try? prWatches.claimDecisionNotifications(watchId: watchId), !decisions.isEmpty,
              let watch = try? prWatches.get(watchId), !watch.paused
        else { return }
        for decision in decisions {
            post(
                "Pull request decision waiting", body: "#\(watch.number): \(decision.decisionQuestion ?? watch.title)",
                projectId: project.id, category: .prDecisions, subject: .pullRequest(watch.id)
            )
        }
    }

    private func startTriageIfSettled(_ watch: PRWatch, project: Project) async {
        let settleMillis = Int64(max(project.settings.prFollowThrough.settleMinutes, 0)) * 60_000
        guard !watch.paused, Int64.nowMillis - (watch.lastFeedbackAt ?? watch.updatedAt) >= settleMillis,
              !isFollowThroughHeld(project: project)
        else { return }
        guard ((try? prWatches.untriagedItemCount(watchId: watch.id)) ?? 0) > 0 else {
            if (try? board.beginAnsweredFixRound(watchId: watch.id)) == .fixing {
                await startFixRound(watch, project: project)
            }
            return
        }
        guard (try? prWatches.beginTriageRound(watchId: watch.id)) != nil else { return }
        do {
            try await spawnTriager(watchId: watch.id)
        } catch {
            failTriageRound(watch, failure: describe(error))
        }
    }

    /// SPEC §13.1's settling holds: the daily budget, AC power and the §8 spawn caps, plus a
    /// shutdown order, which refuses every spawn.
    private func isFollowThroughHeld(project: Project) -> Bool {
        if isShuttingDown(projectId: project.id) || !isOnACPower() { return true }
        if let budget = project.settings.prFollowThrough.dailyBudgetUSD {
            let midnight = Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000)
            if ((try? prWatches.followThroughSpend(projectId: project.id, since: midnight)) ?? 0) >= budget { return true }
        }
        guard case .allowed? = try? CapCheck(db).canSpawn(projectId: project.id) else { return true }
        return false
    }

    private func settleTriageRound(_ watch: PRWatch, project: Project) async {
        guard let triage = try? prWatches.triage(watchId: watch.id, round: watch.round),
              let task = try? tasks.get(triage.taskId)
        else {
            failTriageRound(watch, failure: "round \(watch.round)'s triage never started")
            return
        }
        switch task.column {
        case .done:
            do {
                if let next = try board.applyVerdicts(watchId: watch.id), next != .fixing {
                    await postFactualReplies(watchId: watch.id, project: project)
                }
            } catch {
                report(["could not apply the triage of \(watch.url): \(describe(error))"])
            }
        case .closed:
            failTriageRound(watch, failure: task.closedReason ?? "the triage was closed")
        default:
            // Only a crash between creating the task and assigning its session leaves one with none.
            guard ((try? sessions.forTask(task.id)) ?? []).isEmpty else { return }
            try? tasks.delete(task.id)
            failTriageRound(watch, failure: "the triage never got a session")
        }
    }

    /// SPEC §13.1 fixing and §13.5's §8 amendment: the round's one fixer task, spawned with no
    /// approval while follow-through is on, under the settling holds and every §8 cap. A fixer starts
    /// here once per check, only while the task's fixer sessions do not outnumber its failed checks, so
    /// a failed fixer is not retried in a loop. A round left with nothing to fix ends.
    private func startFixRound(_ watch: PRWatch, project: Project) async {
        do {
            guard let round = try prWatches.currentRound(watchId: watch.id) else { return }
            let model = project.settings.prFollowThrough.roles.fixer?.model
            guard let taskId = try round.fixTaskId ?? board.createFixRoundTask(watchId: watch.id, model: model)?.id else {
                try board.endFixRoundWithoutFixes(watchId: watch.id)
                return
            }
            guard try tasks.get(taskId)?.column == .ready,
                  try sessions.forTask(taskId).filter({ $0.reviewHead == nil }).count <= round.checkFailures,
                  !isFollowThroughHeld(project: project),
                  case .proceed = try board.requestSpawn(taskId: taskId, requestedBy: "follow-through")
            else { return }
            try await spawn(taskId: taskId)
        } catch {
            NSLog("PR follow-through: the fix round of %@ did not start: %@", watch.url, describe(error))
        }
    }

    /// SPEC §13.1 checking: starts the round's reviewer and follow-up check under the settling holds,
    /// then settles the round once both are in. A round that cannot be checked parks its watch.
    private func advanceCheck(_ watch: PRWatch, project: Project) async {
        guard let round = try? prWatches.currentRound(watchId: watch.id), let taskId = round.fixTaskId,
              let task = try? tasks.get(taskId), task.column == .review
        else { return }
        let held = isFollowThroughHeld(project: project)
        do {
            if round.reviewVerdict == nil, try sessions.activeHolder(taskId: taskId) == nil {
                let reviewers = try sessions.forTask(taskId).filter { $0.reviewHead != nil }.count
                if reviewers > round.checkFailures {
                    try board.parkCheck(
                        watchId: watch.id, reason: "Round \(round.number)'s reviewer ended without a verdict."
                    )
                    return
                }
                if !held { try await startRoundReview(task, watch: watch) }
            }
            guard try prWatches.get(watch.id)?.state == .checking else { return }
            if let checkId = round.followupTaskId {
                if let check = try tasks.get(checkId), check.column == .closed {
                    try board.parkCheck(
                        watchId: watch.id,
                        reason: "Round \(round.number)'s follow-up check ended before grading every item: "
                            + (check.closedReason ?? "no reason recorded")
                    )
                    return
                }
            } else if !held, !(try prWatches.checkItems(round: round)).isEmpty {
                try await spawnFollowupCheck(watch, round: round, project: project)
            }
            try board.settleCheck(watchId: watch.id)
        } catch {
            NSLog("PR follow-through: the check of %@ could not run: %@", watch.url, describe(error))
            try? board.parkCheck(
                watchId: watch.id, reason: "Round \(round.number)'s check could not run: \(describe(error))"
            )
        }
    }

    /// An agent reviewer, or a park when the project's routing names none. A round with nothing on its
    /// branch is reopened on the spot rather than handed to a reviewer.
    private func startRoundReview(_ task: BoardTask, watch: PRWatch) async throws {
        switch try board.assignRoundReviewer(taskId: task.id) {
        case .agentReview(let agentId, _):
            do {
                _ = try await spawn(taskId: task.id, rosterAgentId: agentId, scope: .reviewer)
            } catch let empty as NothingToReview {
                try board.recordRoundReview(
                    taskId: task.id, sessionId: nil, reviewerName: "Agent Board", accepted: false, text: empty.reason
                )
            }
        case .humanReview(let reason):
            try board.parkCheck(watchId: watch.id, reason: reason ?? "This round has no agent reviewer.")
        case .autoAccept:
            try board.parkCheck(watchId: watch.id, reason: "This round has no agent reviewer.")
        }
    }

    /// SPEC §13.1 publishing and §13.5's D8 exception, the one push made without an approval: re-reads
    /// the PR, freezes on the verification label, goes stale if the head left the round's base, and
    /// otherwise fast-forwards the checked round branch onto the PR's head ref through `BranchPublisher`.
    private func publishRound(_ watch: PRWatch, project: Project) async {
        guard let round = try? prWatches.currentRound(watchId: watch.id), let taskId = round.fixTaskId,
              let task = try? tasks.get(taskId)
        else { return }
        let settings = project.settings.prFollowThrough
        let repo = URL(fileURLWithPath: project.repoPath)
        let branch = PRRound.branch(pullRequest: watch.number, round: round.number)
        let states = pullRequestStates
        let url = watch.url
        let remote: PullRequestHead
        do {
            remote = try await offMain { try states.head(of: url, cwd: repo) }
        } catch {
            NSLog("PR follow-through: could not re-read %@ before publishing: %@", url, describe(error))
            return
        }
        guard remote.isOpen else { return }
        do {
            if let label = settings.markVerifiedLabel,
               remote.labels.contains(where: { $0.caseInsensitiveCompare(label) == .orderedSame }) {
                try board.freezeRound(watchId: watch.id)
                await dropRoundWorktree(task, project: project)
                return
            }
            let manager = worktreeManager(for: project)
            guard let tip = try await offMain({ try manager.refCommit("refs/heads/\(branch)") }) else {
                try board.parkPublishing(watchId: watch.id, reason: "Round \(round.number)'s branch `\(branch)` is gone.")
                await postFactualReplies(watchId: watch.id, project: project)
                return
            }
            if remote.oid != tip {
                guard remote.oid == round.baseHeadOid else {
                    try board.markRoundStale(watchId: watch.id)
                    await dropRoundWorktree(task, project: project)
                    await postFactualReplies(watchId: watch.id, project: project)
                    return
                }
                if let checked = round.checkedHeadOid, checked != tip {
                    try board.parkPublishing(
                        watchId: watch.id,
                        reason: "Round \(round.number)'s branch moved from \(checked) to \(tip) after its check, so it was not pushed."
                    )
                    await postFactualReplies(watchId: watch.id, project: project)
                    return
                }
                let publisher = BranchPublisher(repoPath: repo, privateTerms: settings.privateTerms)
                let headRef = watch.headRef
                do {
                    _ = try await offMain { try publisher.fastForward(branch: branch, onto: headRef) }
                } catch PublishFailure.notFastForward {
                    try board.markRoundStale(watchId: watch.id)
                    await dropRoundWorktree(task, project: project)
                    await postFactualReplies(watchId: watch.id, project: project)
                    return
                } catch {
                    try board.parkPublishing(
                        watchId: watch.id, reason: "Round \(round.number) was not pushed: \(describe(error))"
                    )
                    await postFactualReplies(watchId: watch.id, project: project)
                    return
                }
            }
            guard try board.recordRoundPublished(watchId: watch.id, pushedHeadOid: tip) != nil else { return }
        } catch {
            NSLog("PR follow-through: publishing %@ could not be recorded: %@", url, describe(error))
            return
        }
        await dropRoundWorktree(task, project: project)
        await postFactualReplies(watchId: watch.id, project: project)
    }

    private func dropRoundWorktree(_ task: BoardTask, project: Project) async {
        guard let taskSessions = try? sessions.forTask(task.id), !taskSessions.contains(where: \.state.isActive) else { return }
        await startTeardown(claimTeardown(of: taskSessions), task: task, project: project, report: nil, landingNotice: nil)
    }

    /// SPEC §13.2: with `postFactualReplies` on, each handled thread item still owed a reply gets one and
    /// each review body a PR comment, its URL recorded. Nothing is resolved. A failed post is recorded on
    /// the item, and abandoned when GitHub says its comment is gone.
    private func postFactualReplies(watchId: String, project: Project) async {
        guard project.settings.prFollowThrough.postFactualReplies, let watch = try? prWatches.get(watchId),
              let items = try? prWatches.pendingReplies(watchId: watchId), !items.isEmpty
        else { return }
        let pushed = Dictionary(
            ((try? prWatches.rounds(watchId: watchId)) ?? []).map { ($0.number, $0.pushedHeadOid) },
            uniquingKeysWith: { first, _ in first }
        )
        let replier = pullRequestReplies
        let cwd = URL(fileURLWithPath: project.repoPath)
        for item in items {
            guard let id = item.id, let text = item.factualReply(pushedHeadOid: pushed[item.round] ?? nil) else { continue }
            let body = item.kind == .review ? item.url.map { "In reply to \($0):\n\n\(text)" } ?? text : text
            do {
                let url: String
                if item.kind == .thread {
                    let thread = item.githubNodeId
                    url = try await offMain { try replier.replyToThread(threadId: thread, body: body, cwd: cwd) }
                } else {
                    let (owner, name, pr) = (watch.repoOwner, watch.repoName, watch.number)
                    url = try await offMain { try replier.comment(owner: owner, name: name, number: pr, body: body, cwd: cwd) }
                }
                try prWatches.recordReply(itemId: id, url: url)
            } catch {
                NSLog("PR follow-through: the reply to %@ on %@ was not posted: %@", item.githubNodeId, watch.url, describe(error))
                try? prWatches.recordReplyFailure(itemId: id, error: describe(error), gone: error is PullRequestReplyTargetGone)
            }
        }
    }

    private func failTriageRound(_ watch: PRWatch, failure: String) {
        NSLog("PR follow-through: the triage of %@ failed: %@", watch.url, failure)
        do {
            try prWatches.abandonTriageRound(watchId: watch.id, failure: failure)
        } catch {
            report(["could not record the failed triage of \(watch.url): \(describe(error))"])
        }
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
    /// attempt is treated as the worktree task it now is (SPEC §5).
    private func sharedBranch(of task: BoardTask) -> String? {
        guard let rows = try? sessions.forTask(task.id) else { return nil }
        guard let newest = rows.first(where: { $0.branch != nil }) else { return nil }
        guard newest.worktreePath == nil, let branch = newest.branch,
              branch.hasPrefix(SharedCheckoutGroup.branchPrefix)
        else { return nil }
        return branch
    }

    /// Every task that has run on `branch`.
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
                members[taskId] = SharedBranchMember(taskId: taskId, isAccepted: task.column == .done)
            }
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
                    + "\nA shared branch merges once, when every task on it has been accepted: its members' "
                    + "commits are interleaved on one ref, so there is no range that is one task's work alone "
                    + "and Agent Board does not unpick commits."
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
        let outcome: BranchMerge
        do {
            outcome = try await offMain {
                try manager.ensureBranch(epicBranch, from: projectBase)
                // Nothing to attribute, and the ledger's tip refs are all that is left to check.
                guard try manager.branchExists(branch) else { return .nothingToMerge }
                let base = try manager.mergeBase(branch, epicBranch) ?? projectBase
                // A branch that predates the ledger has its attribution only in its old trailers,
                // and this is the last moment anything reads it: reaping deletes the ref.
                _ = try? manager.backfillFromTrailers(on: branch, since: base)
                // Written before the merge, because the branch is about to be deleted and the refs
                // are all that is left to say which commit was whose.
                try manager.recordSharedLedger(branch: branch, base: base, taskIds: memberIds)
                return try manager.merge(
                    taskBranch: branch, into: epicBranch, taskTitle: mergeTitle,
                    targetTitle: epicTitle
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
        case .nothingToMerge:
            await recordVanishedSharedBranch(branch, members: memberIds, accepted: task, epic: epic, project: project)
        case .alreadyMerged, .fastForwarded, .merged:
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

    /// SPEC §5: a shared branch already gone when its last member is accepted merged nothing, so
    /// each member's landing is whether the epic branch holds the commits the ledger attributes to it.
    private func recordVanishedSharedBranch(
        _ branch: String, members memberIds: [String], accepted task: BoardTask, epic: Epic, project: Project
    ) async {
        let manager = worktreeManager(for: project)
        let epicBranch = epic.branch
        let ledger = TaskCommitStore(db)
        let checked: [(id: String, commits: [String], missing: [String])]
        do {
            let wanted = try memberIds.map { (id: $0, shas: try ledger.shas(taskId: $0)) }
            checked = try await offMain {
                try wanted.map { member in
                    let commits = try Self.ledgeredCommits(manager, taskId: member.id, shas: member.shas)
                    let missing = try commits.filter {
                        try !manager.commitExists($0) || !manager.isMerged(commit: $0, into: "refs/heads/\(epicBranch)")
                    }
                    return (member.id, commits, missing)
                }
            }
        } catch {
            recordLanding(
                task: task, epic: epic, landing: .unlanded,
                detail: "`\(branch)` was already gone when its last task was accepted, and whether the epic "
                    + "branch `\(epicBranch)` holds its tasks' commits could not be checked: \(describe(error))",
                advice: "Check each task's commits against `\(epicBranch)` by hand."
            )
            return
        }
        let gone = "`\(branch)`, shared by \(memberIds.count) task\(memberIds.count == 1 ? "" : "s"), was already "
            + "gone when the last of them was accepted, so nothing was merged"
        for member in checked {
            guard let row = (try? tasks.get(member.id)) ?? nil else { continue }
            let isAccepting = member.id == task.id
            if member.commits.isEmpty {
                recordLanding(
                    task: row, epic: epic, landing: .noBranch,
                    detail: gone + ", and the ledger attributes no commit to this task.",
                    advice: nil, reportAlways: isAccepting
                )
            } else if member.missing.isEmpty {
                recordLanding(
                    task: row, epic: epic, landing: .landed,
                    detail: gone + "; `\(epicBranch)` already contains every commit the ledger attributes to this task.",
                    advice: nil, reportAlways: isAccepting
                )
            } else {
                recordLanding(
                    task: row, epic: epic, landing: .unlanded,
                    detail: gone + ", and the epic branch `\(epicBranch)` lacks these commits the ledger attributes "
                        + "to this task:\n" + member.missing.map { "- \($0)" }.joined(separator: "\n"),
                    advice: "The branch that carried them is deleted. Dispatch a task to cherry-pick them onto `\(epicBranch)`."
                )
            }
        }
    }

    /// The commits `task_commit` attributes to a shared-branch member, plus the tip the ledger kept
    /// for it unless that tip is its base, which is how the ledger records "committed nothing".
    private nonisolated static func ledgeredCommits(
        _ manager: WorktreeManager, taskId: String, shas: [String]
    ) throws -> [String] {
        var commits = shas
        if let tip = try manager.refCommit(TaskBranchLedger.tipRef(taskId: taskId)),
           try tip != manager.refCommit(TaskBranchLedger.baseRef(taskId: taskId)),
           !commits.contains(tip) {
            commits.append(tip)
        }
        return commits
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
        let notices = await offMainResult {
            do {
                try manager.releaseSharedBranch(branch, to: epicBranch)
            } catch {
                return ["kept shared branch \(branch): \(error)"]
            }
            return Self.deleteBranch(manager, branch, bases: bases)
        }
        report(notices)
    }

    /// Writes the landing and queues a `decision` report when the human has something to do about
    /// it, or, with `reportAlways`, when the accept merged nothing (SPEC §5). The write comes first:
    /// a report that fails to insert must not also lose the state the board renders.
    private func recordLanding(
        task: BoardTask, epic: Epic?, landing: TaskLanding, detail: String?, advice: String?,
        reportAlways: Bool = false
    ) {
        do {
            try tasks.setLanding(task.id, landing, detail: detail)
        } catch {
            report(["could not record where \(task.id) landed: \(describe(error))"])
        }
        // An open pull request is already in front of the human; the merge check reports if it closes.
        guard (landing.needsAttention && landing != .pullRequestOpen) || reportAlways, let detail else { return }
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
        guard landing.needsAttention else { return }
        report([epic.map { "epic \($0.id): " + text } ?? text])
    }

    func reopen(taskId: String) async throws {
        try await recording {
            try await stopLiveSessions(onTask: taskId, by: .human)
            let report = try board.reopen(taskId: taskId)
            report.projectId.map { announceReports(projectId: $0) }
        }
    }

    func rerunReview(taskId: String) async throws {
        try await recording {
            guard let task = try tasks.get(taskId) else { throw SupervisorError.taskNotFound(taskId) }
            guard task.column == .review, let reviewerId = task.reviewerAgentId else {
                throw SupervisorError.noReviewToRerun(title: task.title)
            }
            try await stopLiveSessions(onTask: taskId, by: .human)
            _ = try await spawn(taskId: taskId, rosterAgentId: reviewerId, scope: .reviewer)
        }
    }

    func discard(taskId: String) async throws {
        try await recording {
            guard let task = try tasks.get(taskId) else { throw SupervisorError.taskNotFound(taskId) }
            guard let project = try projects.get(task.projectId) else {
                throw SupervisorError.projectNotFound(task.projectId)
            }
            let taskSessions = try sessions.forTask(taskId)
            discarding.insert(taskId)
            defer { discarding.remove(taskId) }
            var setups: [_Concurrency.Task<Void, Never>] = []
            for session in taskSessions where session.state.isActive {
                if let shortId = session.shortId {
                    try? await stopAgent(session, shortId: shortId)
                } else if let setup = setupTasks[session.sessionId] {
                    setup.cancel()
                    setups.append(setup)
                }
                try board.endSession(session.sessionId, .stopped, endedAt: .nowMillis)
            }
            for session in taskSessions {
                try grants.revokeAll(sessionId: session.sessionId)
            }
            // SPEC §5: a setup still running would create the worktree after the teardown looked for it.
            for setup in setups { await setup.value }
            let cleanup = await tearDownWorktrees(claimTeardown(of: taskSessions), task: task, project: project)
            report(cleanup.notices)
            try board.discard(taskId: taskId, cleanup: cleanup.findings.map(\.text))
            announceReports(projectId: project.id)
        }
    }

    func reconcile(projectId: String) async {
        while let running = worktreeSweeps[projectId] { await running.value }
        await startWorktreeSweep(projectId: projectId) { await $0.reconcileNow(projectId: projectId) }.value
    }

    private func startWorktreeSweep(
        projectId: String, _ body: @escaping @MainActor (WorkerSupervisor) async -> Void
    ) -> _Concurrency.Task<Void, Never> {
        let sweep = _Concurrency.Task { [weak self] in
            guard let self else { return }
            await body(self)
            worktreeSweeps[projectId] = nil
        }
        worktreeSweeps[projectId] = sweep
        return sweep
    }

    private func reconcileNow(projectId: String) async {
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
                    let report = (try? terminateSession(
                        session.sessionId, cause: .vanished, salvage: salvage
                    )) ?? nil
                    queuedReport = queuedReport || report != nil
                    await reapProcesses(of: session, listing: listed)
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
                    let report = (try? terminateSession(
                        session.sessionId, cause: .vanished, salvage: salvage
                    )) ?? nil
                    queuedReport = queuedReport || report != nil
                    await reapProcesses(of: session, listing: listed)
                }
            } else if status == "running" {
                if session.state == .stopped || session.state.isActive, let taskId = session.taskId,
                   !resuming.contains(session.sessionId),
                   (try? board.isSettled(taskId: taskId, apartFrom: session.sessionId)) == true {
                    let queued = await stopOnSettledTask(session, listed: info, in: listed)
                    queuedReport = queuedReport || queued
                } else if [.starting, .idle, .stopped].contains(session.state) {
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

    /// SPEC §10, Status: nothing belongs running on a settled task, so its process is stopped and
    /// its row is not revived. True when that queued a report.
    private func stopOnSettledTask(_ session: AgentSession, listed info: AgentInfo, in listing: [AgentInfo]) async -> Bool {
        guard let shortId = session.shortId ?? info.id,
              (try? await stopAgent(session, shortId: shortId, listing: listing)) != nil,
              session.state.isActive
        else { return false }
        let report = (try? terminateSession(session.sessionId, cause: .taskSettled)) ?? nil
        try? grants.revokeAll(sessionId: session.sessionId)
        return report != nil
    }

    func attachCommand(sessionId: String) -> (executable: String, arguments: [String])? {
        guard let shortId = try? sessions.get(sessionId)?.shortId else { return nil }
        attachRequestedAt[sessionId] = .nowMillis
        return runtime.attachCommand(shortId: shortId)
    }

    func worktreeDiffstat(taskId: String) async -> String? {
        guard let context = diffContext(taskId: taskId) else { return nil }
        return try? await offMain {
            switch context.site {
            case .worktree(let path):
                return try context.manager.diffstat(worktree: path, against: context.diffBase)
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
                return try context.manager.diffSummary(worktree: path, against: context.diffBase)
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
        /// Set for a standalone task, whose branch may be cut from the remote's base (SPEC §3.1 step 1).
        var standaloneTaskId: String?

        /// Runs git, so only off main.
        var diffBase: String {
            standaloneTaskId.map { manager.diffBase(taskId: $0, base: base) } ?? base
        }

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
            manager: manager, site: .worktree(URL(fileURLWithPath: worktreePath)), base: project.baseBranch,
            standaloneTaskId: task.epicId == nil ? taskId : nil
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

    private struct TeardownClaim: Sendable {
        var paths: [String] = []
        var resolvedPaths: [String] = []
        /// Another teardown holds one of the paths, and will delete the branch when it is done.
        var leavesBranch = false
    }

    /// Takes every path no other teardown already holds; `releaseTeardown` gives them back.
    private func claimTeardown(of paths: [String]) -> TeardownClaim {
        var claim = TeardownClaim()
        for path in paths {
            let resolvedPath = Self.resolved(path)
            if claim.resolvedPaths.contains(resolvedPath) { continue }
            if tearingDown.contains(resolvedPath) {
                claim.leavesBranch = true
                continue
            }
            tearingDown.insert(resolvedPath)
            claim.paths.append(path)
            claim.resolvedPaths.append(resolvedPath)
        }
        return claim
    }

    /// A retried task has one worktree per attempt, so every session is torn down, not just the newest.
    private func claimTeardown(of taskSessions: [AgentSession]) -> TeardownClaim {
        claimTeardown(of: taskSessions.compactMap(\.worktreePath))
    }

    private func releaseTeardown(_ claim: TeardownClaim) {
        tearingDown.subtract(claim.resolvedPaths)
        for path in claim.resolvedPaths {
            teardownWaiters.removeValue(forKey: path)?.forEach { $0.resume() }
        }
    }

    private func awaitTeardown(of path: String) async {
        let resolvedPath = Self.resolved(path)
        while tearingDown.contains(resolvedPath) {
            await withCheckedContinuation { teardownWaiters[resolvedPath, default: []].append($0) }
        }
    }

    private func tearDownWorktrees(_ claim: TeardownClaim, task: BoardTask, project: Project) async -> WorktreeCleanup {
        defer { releaseTeardown(claim) }
        let manager = worktreeManager(for: project)
        let branch = claim.leavesBranch ? nil : Self.taskBranchPrefix + task.id
        let bases = mergeTargets(for: task, project: project)
        let paths = claim.paths
        return await offMainResult {
            Self.tearDown(manager: manager, paths: paths, branch: branch, bases: bases)
        }
    }

    /// The metering tick's reap, so orphans go without the Status view open. It starts each project's
    /// sweep without waiting on it, and skips a project whose `reconcile` is running (SPEC §5).
    private func reapOrphanedWorktreesOnTick(_ all: [Project]) {
        for project in all where worktreeSweeps[project.id] == nil {
            _ = startWorktreeSweep(projectId: project.id) { supervisor in
                guard let ours = try? supervisor.sessions.all(projectId: project.id) else { return }
                let live = Set(ours.filter { $0.state.isActive }.compactMap(\.worktreePath))
                await supervisor.reapOrphanedWorktrees(projectId: project.id, keeping: live)
            }
        }
    }

    func waitForWorktreeSweeps() async {
        while let sweep = worktreeSweeps.values.first {
            await sweep.value
        }
    }

    /// Sessions that failed or were stopped on a task nobody accepted or discarded leave their
    /// worktree behind, as do sessions whose task record is already gone.
    /// Behind a teardown hook the removals run in the background, so `reconcile` returns promptly.
    private func reapOrphanedWorktrees(projectId: String, keeping live: Set<String>) async {
        guard let project = try? projects.get(projectId) else { return }
        let manager = worktreeManager(for: project)
        let bases = [project.baseBranch] + ((try? epics.list(projectId: projectId)) ?? []).map(\.branch)
        let keeping = live.union(tearingDown).union(placing)
        let scan = await offMainResult {
            Self.orphans(manager: manager, keeping: keeping, bases: bases)
        }
        report(scan.notices)
        // `live` predates the scan, so a spawn that created its worktree and wrote its row meanwhile is in neither.
        guard let current = try? sessions.all(projectId: projectId) else { return }
        let held = Set(current.filter { $0.state.isActive }.compactMap(\.worktreePath).map(Self.resolved))
            .union(placing.map(Self.resolved))
        let claim = claimTeardown(of: scan.orphans.filter { !held.contains($0.path) }.map(\.url.path))
        let orphans = scan.orphans.filter { claim.paths.contains($0.url.path) }
        let removal: @MainActor (WorkerSupervisor) async -> Void = { supervisor in
            defer { supervisor.releaseTeardown(claim) }
            var cleanup = await supervisor.offMainResult {
                Self.reap(manager: manager, orphans: orphans, bases: bases)
            }
            cleanup.notices += await supervisor.sweepMergedBranches(manager, bases: bases)
            supervisor.recordReap(cleanup, projectId: projectId)
        }
        if project.settings.worktreeTeardown != nil, !orphans.isEmpty {
            inBackground(removal)
        } else {
            await removal(self)
        }
    }

    private func recordReap(_ cleanup: WorktreeCleanup, projectId: String) {
        report(cleanup.notices)
        guard !cleanup.findings.isEmpty else { return }
        let owners = (try? sessions.all(projectId: projectId)) ?? []
        var queued = false
        for finding in cleanup.findings {
            let owner = owners.first { $0.worktreePath.map(Self.resolved) == Self.resolved(finding.path) }?.taskId
            if let owner,
               (try? board.recordWorktreeCleanup(taskId: owner, reportId: nil, findings: [finding.text])) == true {
                queued = true
            }
        }
        if queued { announceReports(projectId: projectId) }
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
            worktreeRoot: WorktreeRootRule.url(project.worktreeRoot, home: home),
            attribution: .ledger(TaskCommitStore(db)),
            teardown: project.settings.worktreeTeardown
        )
    }

    private nonisolated static func tearDown(
        manager: WorktreeManager, paths: [String], branch: String?, bases: [String]
    ) -> WorktreeCleanup {
        var cleanup = WorktreeCleanup()
        var removedEvery = true
        for path in paths where FileManager.default.fileExists(atPath: path) {
            switch removeIfClean(manager, at: URL(fileURLWithPath: path)) {
            case .removed(let diagnostics, let teardownFailure):
                cleanup.notices.append(contentsOf: diagnostics)
                if let teardownFailure { cleanup.add(teardownFailure, at: path) }
            case .kept(let reason):
                cleanup.add(reason, at: path)
                removedEvery = false
            }
        }
        guard removedEvery, let branch else { return cleanup }
        cleanup.notices.append(contentsOf: deleteBranch(manager, branch, bases: bases))
        return cleanup
    }

    private struct Orphan: Sendable {
        var url: URL
        var path: String
        var branch: String?
    }

    private nonisolated static func orphans(
        manager: WorktreeManager, keeping live: Set<String>, bases: [String]
    ) -> (orphans: [Orphan], notices: [String]) {
        guard let listed = try? manager.list() else { return ([], []) }
        let root = resolved(manager.worktreeRoot.path)
        let liveRoots = Set(live.map(resolved))
        var orphans: [Orphan] = []
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
            orphans.append(Orphan(url: info.path, path: path, branch: info.branch))
        }
        return (orphans, notices)
    }

    /// Only a teardown hook's failure is a finding here: a kept orphan is noticed again on every
    /// sweep, and the status bar is where that belongs.
    private nonisolated static func reap(
        manager: WorktreeManager, orphans: [Orphan], bases: [String]
    ) -> WorktreeCleanup {
        var cleanup = WorktreeCleanup()
        var notices: [String] = []
        for orphan in orphans {
            switch removeIfClean(manager, at: orphan.url) {
            case .removed(let diagnostics, let teardownFailure):
                notices.append(contentsOf: diagnostics)
                if let teardownFailure { cleanup.add(teardownFailure, at: orphan.path) }
                if let branch = orphan.branch {
                    notices.append(contentsOf: deleteBranch(manager, branch, bases: bases))
                }
            case .kept(let reason):
                notices.append(reason)
            }
        }
        cleanup.notices.insert(contentsOf: notices, at: 0)
        return cleanup
    }

    /// Task branches outlive their worktree: every accepted task before this swept them up leaves one
    /// behind. Only failures are reported, since an unmerged branch is the normal in-flight state. An
    /// unreadable worktree record blocks every branch's holder check, so it is named once per sweep.
    /// A spawn's new branch has no commits and reads as merged, so a task being placed keeps its branch,
    /// and every other worktree-less task's path is claimed until its branch is gone (SPEC §5).
    private func sweepMergedBranches(_ manager: WorktreeManager, bases: [String]) async -> [String] {
        let candidates = await offMainResult { Self.worktreelessTaskBranches(manager) }
        let placed = Set(placing.map(Self.resolved))
        let claim = claimTeardown(of: candidates.map(\.path).filter { !placed.contains(Self.resolved($0)) })
        defer { releaseTeardown(claim) }
        let branches = candidates.filter { claim.paths.contains($0.path) }.map(\.branch)
        return await offMainResult { Self.deleteMergedBranches(manager, branches, bases: bases) }
    }

    /// A branch whose worktree is on disk is kept by the holder check, so only the rest need a claim.
    private nonisolated static func worktreelessTaskBranches(_ manager: WorktreeManager) -> [(branch: String, path: String)] {
        guard let branches = try? manager.localBranches(withPrefix: taskBranchPrefix) else { return [] }
        return branches
            .filter { !$0.hasPrefix(EpicStore.branchPrefix) && !$0.hasPrefix(SharedCheckoutGroup.branchPrefix) }
            .map { ($0, manager.worktreeRoot.appendingPathComponent(String($0.dropFirst(taskBranchPrefix.count))).path) }
            .filter { !FileManager.default.fileExists(atPath: $0.path) }
    }

    private nonisolated static func deleteMergedBranches(
        _ manager: WorktreeManager, _ branches: [String], bases: [String]
    ) -> [String] {
        var failures: [String] = []
        var blocked: [String: (record: UnreadableWorktreeRecord, branches: Int)] = [:]
        for branch in branches {
            do {
                if case .keptUnreadable(_, let record) = try manager.deleteBranchIfMerged(branch, into: bases) {
                    blocked[record.directory, default: (record, 0)].branches += 1
                }
            } catch {
                failures.append("could not delete branch \(branch): \(error)")
            }
        }
        return failures + blocked.keys.sorted().compactMap { blocked[$0] }.map {
            "kept \($0.branches) task branch\($0.branches == 1 ? "" : "es") without checking whether they were merged: "
                + "\($0.record). Fix that directory's permissions, or remove it if its worktree is gone."
        }
    }

    private enum WorktreeTeardown {
        case removed([String], teardownFailure: String?)
        case kept(String)
    }

    nonisolated static let dirtyPathsListed = 20

    /// SPEC §5: a worktree with uncommitted changes is kept, and the teardown hook does not run in it.
    private nonisolated static func removeIfClean(_ manager: WorktreeManager, at path: URL) -> WorktreeTeardown {
        do {
            let dirty = try manager.uncommittedPaths(worktree: path)
            if !dirty.isEmpty {
                let listed = dirty.prefix(dirtyPathsListed).joined(separator: ", ")
                let more = dirty.count > dirtyPathsListed ? " and \(dirty.count - dirtyPathsListed) more" : ""
                return .kept("kept worktree \(path.path): it has uncommitted changes in \(listed)\(more)")
            }
            let removal = try manager.remove(path: path)
            return .removed(removal.hookDiagnostics, teardownFailure: removal.teardownFailure)
        } catch {
            return .kept("could not remove worktree \(path.path): \(error)")
        }
    }

    private nonisolated static func deleteBranch(
        _ manager: WorktreeManager, _ branch: String, bases: [String]
    ) -> [String] {
        do {
            switch try manager.deleteBranchIfMerged(branch, into: bases) {
            case .kept(let branch, let reason): return ["kept branch \(branch): \(reason)"]
            case .keptUnreadable(let branch, let record): return ["kept branch \(branch): \(record)"]
            case .deleted, .noSuchBranch: return []
            }
        } catch {
            return ["could not delete branch \(branch): \(error)"]
        }
    }

    private nonisolated static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func offMainResult<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
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
            projectsRoot: projectsRoot,
            claude: claude,
            currentPort: { [weak self] in self?.serverPort }
        )
        consoles[projectId] = console
        return console
    }

    /// The one Coordinator console (SPEC §8.2), created on first call; does not start the process.
    func coordinatorSessionConsole() -> OrchestratorConsole {
        if let existing = coordinatorConsoleInstance { return existing }
        let console = OrchestratorConsole(
            source: CoordinatorSource(
                db: db, folder: coordinatorDir, home: home, sessionConfigDir: sessionConfigDir,
                projectsRoot: projectsRoot, claude: claude
            ),
            db: db,
            currentPort: { [weak self] in self?.serverPort }
        )
        console.liveChanged = { [weak self, weak console] live in
            self?.coordinatorConsole = live ? console : nil
        }
        coordinatorConsoleInstance = console
        return console
    }

    /// Ends the running Coordinator session, which stays in the history and resumable, and starts
    /// a fresh one. The ended session's grant is revoked, so it can no longer call Coordinator tools.
    func newCoordinatorSession() throws {
        try grants.revokeCoordinatorGrants()
        try coordinator.setActiveSession(nil)
        coordinatorSessionConsole().restart()
    }

    /// Makes a previous Coordinator session the active one and resumes it in place of the current,
    /// revoking the current one's grant; the resumed launch is issued a fresh one.
    func resumeCoordinatorSession(sessionId: String) throws {
        guard let row = try sessions.get(sessionId), row.role == .coordinator else {
            throw SupervisorError.sessionNotFound(sessionId)
        }
        try grants.revokeCoordinatorGrants()
        try coordinator.setActiveSession(sessionId)
        coordinatorSessionConsole().restart()
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
        let publisher = BranchPublisher(
            repoPath: URL(fileURLWithPath: project.repoPath),
            privateTerms: project.settings.prFollowThrough.privateTerms
        )
        let base = request.base ?? project.baseBranch
        do {
            switch approval.kind {
            case .push:
                let result = try await offMain {
                    try publisher.push(
                        branch: request.branch, publishedAs: request.publishedBranch, base: base,
                        remote: request.remote
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
            report.projectId.map { announceReports(projectId: $0) }
        }
    }

    /// SPEC §5.2: what Remove worktrees on a done or abandoned epic's lane would remove.
    func heldWorktrees(epicId: String) throws -> [HeldWorktree] {
        try board.heldWorktrees(epicId: epicId)
    }

    /// SPEC §5.2: removes the worktrees a done or abandoned epic left on disk, each through the
    /// project's teardown hook. A worktree a live session holds, or one with uncommitted changes,
    /// is kept and named. Branches are left alone.
    func removeEpicWorktrees(epicId: String) async throws {
        try await recording {
            guard let epic = try epics.get(epicId) else { throw SupervisorError.epicNotFound(epicId) }
            guard epic.state.isTerminal else { throw SupervisorError.epicStillOpen(epicId) }
            guard let project = try projects.get(epic.projectId) else {
                throw SupervisorError.projectNotFound(epic.projectId)
            }
            var findings: [WorktreeCleanupFinding] = []
            var removable: [HeldWorktree] = []
            for worktree in try board.heldWorktrees(epicId: epicId) {
                if let holder = try sessions.activeHolder(worktreePath: worktree.path) {
                    findings.append(WorktreeCleanupFinding(
                        taskId: worktree.taskId,
                        text: "kept worktree \(worktree.path): session \(holder.sessionId) is still running in it"
                    ))
                } else {
                    removable.append(worktree)
                }
            }
            let claim = claimTeardown(of: removable.map(\.path))
            defer { releaseTeardown(claim) }
            for worktree in removable where !claim.paths.contains(worktree.path) {
                findings.append(WorktreeCleanupFinding(
                    taskId: worktree.taskId, text: "kept worktree \(worktree.path): another teardown is removing it"
                ))
            }
            let manager = worktreeManager(for: project)
            let candidates = removable.filter { claim.paths.contains($0.path) }
            let outcomes = await offMainResult {
                candidates.map { ($0, Self.removeIfClean(manager, at: URL(fileURLWithPath: $0.path))) }
            }
            var removed: [String] = []
            var notices: [String] = []
            for (worktree, outcome) in outcomes {
                switch outcome {
                case .removed(let diagnostics, let teardownFailure):
                    removed.append(worktree.path)
                    notices.append(contentsOf: diagnostics)
                    if let teardownFailure {
                        findings.append(WorktreeCleanupFinding(taskId: worktree.taskId, text: teardownFailure))
                    }
                case .kept(let reason):
                    findings.append(WorktreeCleanupFinding(taskId: worktree.taskId, text: reason))
                }
            }
            report(notices + findings.map(\.text))
            try board.recordEpicWorktreeRemoval(epicId: epicId, removed: removed, findings: findings)
            announceReports(projectId: project.id)
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
            let active = try sessions.active(projectId: projectId).filter { $0.role == .worker }
            // SPEC §13.2: a triager has no acknowledge_shutdown and is never resumed, so it is stopped
            // outright, and its round is retried once the order lifts rather than counted as failed.
            let triagers = Set(active.filter { session in
                session.taskId.flatMap { try? tasks.get($0) }?.origin.isPullRequestReader == true
            }.map(\.sessionId))
            for triager in active where triagers.contains(triager.sessionId) {
                if let triage = triager.taskId.flatMap({ try? prWatches.triage(taskId: $0) }) {
                    _ = try? prWatches.abandonTriageRound(watchId: triage.watchId, failure: nil)
                }
                if let taskId = triager.taskId { try? prWatches.interruptFollowupCheck(taskId: taskId) }
                try? await stopSession(triager.sessionId, by: .human)
            }
            let workers = active.filter { $0.state != .setup && !triagers.contains($0.sessionId) }
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
        coordinatorConsoleInstance?.stop()
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
        do {
            return try await spawn(taskId: taskId, rosterAgentId: rosterAgentId, scope: scope)
        } catch let declined as NothingToReview {
            throw declined
        } catch {
            lastError = describe(error)
            throw error
        }
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

    /// Read before each follow-through spawn (SPEC §13.1); a test substitutes the answer.
    @ObservationIgnored var isOnACPower: @MainActor () -> Bool = { PowerSource.isOnAC() }

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

    func coordinatorReportQueued() async {
        coordinatorConsole?.reportsChanged()
    }

    /// A stale Coordinator session's hooks still reach the board; only the active one's are heard.
    func coordinatorTurnEnded(sessionId: String) async {
        guard isActiveCoordinatorSession(sessionId) else { return }
        coordinatorConsole?.turnEnded()
    }

    func coordinatorCompacted(sessionId: String, manual: Bool) async {
        guard isActiveCoordinatorSession(sessionId) else { return }
        coordinatorConsoleInstance?.compactionCompleted(manual: manual)
    }

    private func isActiveCoordinatorSession(_ sessionId: String) -> Bool {
        (try? coordinator.activeSessionId()) == sessionId
    }

    /// The worker has committed and recorded its note; this is the orderly end of its session. The
    /// cause is neither a human kill nor a cap kill, and `terminate` puts the unfinished task back
    /// in `ready` with the note attached to the report.
    func workerAcknowledgedShutdown(projectId: String, sessionId: String) async {
        guard let session = try? sessions.get(sessionId) else { return }
        let note = try? shutdowns.outstanding(projectId: projectId)
            .flatMap { try deliveries.get(orderId: $0.id, sessionId: sessionId)?.note }
        if let shortId = session.shortId {
            try? await stopAgent(session, shortId: shortId)
        }
        _ = try? terminateSession(sessionId, cause: .shutdownAcknowledged(note: note ?? nil))
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
        try? await stopAgent(session, shortId: shortId)
        await tearDownFinishedTriage(session)
    }

    /// Every way a session ends goes through here, so a triage's checkout goes however it ended.
    @discardableResult
    private func terminateSession(
        _ sessionId: String, cause: SessionTermination, salvage: BranchSalvage? = nil
    ) throws -> Report? {
        let report = try board.terminate(sessionId: sessionId, cause: cause, salvage: salvage)
        if let session = try? sessions.get(sessionId), let taskId = session.taskId,
           (try? tasks.get(taskId))?.origin.isPullRequestReader == true {
            inBackground { await $0.tearDownFinishedTriage(session) }
        }
        return report
    }

    /// SPEC §13.1, §13.2: a triage or follow-up check lands nothing, and its detached checkout of the PR
    /// head always has commits outside the project's bases, so the orphan sweep would keep it forever.
    private func tearDownFinishedTriage(_ session: AgentSession) async {
        guard let taskId = session.taskId, let task = try? tasks.get(taskId), task.origin.isPullRequestReader,
              task.column == .done || task.column == .closed, let project = try? projects.get(task.projectId),
              let taskSessions = try? sessions.forTask(taskId), !taskSessions.contains(where: \.state.isActive)
        else { return }
        await startTeardown(
            claimTeardown(of: taskSessions), task: task, project: project, report: nil, landingNotice: nil
        )
    }

    /// SPEC §8.5: a session the board ended is stopped again when Claude Code resumes it on its own,
    /// as it does to deliver a background command's notification. A board resume in flight and a
    /// human who attached after the session ended are the two restarts that are meant.
    func endedSessionRestarted(projectId: String, sessionId: String) async {
        guard !resuming.contains(sessionId),
              let session = try? sessions.get(sessionId),
              session.state == .failed || session.state == .completed
                  || !((try? grants.hasLiveGrant(sessionId: sessionId)) ?? true),
              let shortId = session.shortId
        else { return }
        if let attached = attachRequestedAt[sessionId], attached >= session.endedAt ?? 0 { return }
        try? await stopAgent(session, shortId: shortId)
        if let taskId = session.taskId {
            _ = try? ProgressStore(db).append(
                taskId: taskId, sessionId: sessionId, kind: .status,
                text: "Claude Code resumed \(session.displayShortId), which Agent Board had already ended "
                    + "(\(session.state.rawValue)); it was stopped again."
            )
        }
    }

    /// Stops the agent of every session this board's own rows say is finished — the backlog left by
    /// every worker that completed before `report_complete` learned to stop its own session.
    ///
    /// Every target comes from `agent_session`, and the runtime list read afterwards can only
    /// subtract. A `claude` session with no row here is never a candidate, whatever its process
    /// looks like: argv and environment cannot tell a parked spare from a session doing real work.
    /// A row whose agent a `claude stop` already confirmed stopped is not planned (SPEC §8.6).
    @discardableResult
    func sweepLeakedAgents(dryRun: Bool = false) async -> AgentSweepReport {
        var report = AgentSweepReport(dryRun: dryRun)
        let projectIds = ((try? projects.list()) ?? []).map(\.id)
        let rows = projectIds.flatMap { (try? sessions.sweepCandidates(projectId: $0)) ?? [] }
        let confirmed = projectIds.flatMap { (try? sessions.confirmedStoppedShortIds(projectId: $0)) ?? [] }
        report.confirmedStopped = confirmed.count
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
                if let session = rows.first(where: { $0.sessionId == decision.sessionId }) {
                    try await stopAgent(session, shortId: shortId, listing: listed)
                } else {
                    try await runtime.stop(shortId: shortId)
                    try? sessions.markAgentStopped(decision.sessionId)
                }
                report.stopped.append(decision)
            } catch {
                report.failed.append(LeakedAgentSweep.Decision(
                    sessionId: decision.sessionId, shortId: shortId, outcome: .stop,
                    reason: describe(error)
                ))
            }
        }
        if let listed, let resident {
            let known = Set(rows.compactMap(\.shortId)).union(confirmed)
            report.untracked = listed
                .filter { $0.pid != nil && $0.id.map { !known.contains($0) } ?? true }
                .count
            report.confirmedStoppedButListed = confirmed.filter(resident.contains).count
        }
        return report
    }

    func previewLeakedAgentSweep() async -> AgentSweepReport? {
        await sweepLeakedAgents(dryRun: true)
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
        if pollsPRWatchesOnTick, now - lastPRWatchPoll >= Self.prWatchPollIntervalMillis {
            lastPRWatchPoll = now
            // A slow `gh` must not queue a poll per tick behind the one still running.
            if prWatchPoll == nil { _Concurrency.Task { await self.pollPRWatches() } }
        }
        if now - lastOrphanReap >= Self.orphanReapIntervalMillis {
            lastOrphanReap = now
            reapOrphanedWorktreesOnTick(all)
        }
        var metered: Set<String> = []
        for project in all {
            refreshShutdownProgressIfOrdered(projectId: project.id)
            await recoverStrandedTasks(projectId: project.id)
            let limits = Self.capLimits(project.settings.caps)
            guard let projectSessions = try? sessions.all(projectId: project.id) else { continue }
            let stallSeconds = project.settings.caps.stallSeconds
            for session in projectSessions where Self.shouldMeter(session, now: now) {
                metered.insert(session.sessionId)
                await meter(session, limits: limits, stallSeconds: stallSeconds, awake: awake)
            }
        }
        // Metered like an orchestrator, with no cap: `meter` enforces caps on workers only.
        for session in (try? coordinator.sessions()) ?? [] where Self.shouldMeter(session, now: now) {
            metered.insert(session.sessionId)
            await meter(session, limits: .default, stallSeconds: 0, awake: awake)
        }
        transcriptTailers = transcriptTailers.filter { metered.contains($0.key) }
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
        _ = try? messages.deleteExpired(now: now)
        _ = try? requests.deleteExpired(now: now)
        _ = try? hookEvents.prune(now: now)
        return all.flatMap { (try? archives.run(projectId: $0.id, now: now)) ?? [] }
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
            let tailer = transcriptTailers[session.sessionId].flatMap { $0.url == url ? $0 : nil }
                ?? TranscriptTailer(url: url)
            if let polled = try? await offMain({
                var next = tailer
                try next.poll()
                return next
            }) {
                transcriptTailers[session.sessionId] = polled
                let summary = polled.summary
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
        if current.role == .coordinator, let context {
            coordinatorConsoleInstance?.contextPressureObserved(context)
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
            try? await stopAgent(session, shortId: shortId)
        }
        let salvage = await branchSalvage(taskId: session.taskId)
        _ = try? terminateSession(session.sessionId, cause: .capBreach(description), salvage: salvage)
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
