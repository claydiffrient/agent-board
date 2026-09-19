import AgentBoardCore
import Observation

@Observable
@MainActor
final class AppEnvironment {
    let db: AppDatabase
    let supervisor: any WorkerSupervising
    let router: NotificationRouter
    /// One model for the window, so the sidebar footer's poll is owned here rather than started
    /// afresh by every `AccountUsageFooter` body — and so an offscreen render test can hand in one
    /// that reads nothing and therefore never redraws mid-capture.
    let accountUsage: AccountUsageModel
    /// The same instance the supervisor drives, so the Status footer reads the assertion that is
    /// actually held rather than a second copy of the decision. SPEC §8.3.
    let sleepGuard: SleepGuard
    /// Quitting is not `NSApplication.terminate` on its own — see `AppQuitting` — and a test needs
    /// a seam that does not end the test process.
    let quitter: any AppQuitting
    let releaseNotes: ReleaseNotesAnnouncer
    /// `supervisor.start()`, so a launch-time screen can wait for the server bind, the stale-lock
    /// sweep and the worktree-root migration to finish. Nil everywhere the supervisor is a stub.
    let startup: _Concurrency.Task<Void, Never>?

    init(
        db: AppDatabase, supervisor: any WorkerSupervising, router: NotificationRouter? = nil,
        accountUsage: AccountUsageModel? = nil, sleepGuard: SleepGuard? = nil,
        quitter: (any AppQuitting)? = nil,
        releaseNotes: ReleaseNotesAnnouncer = ReleaseNotesAnnouncer(),
        startup: _Concurrency.Task<Void, Never>? = nil
    ) {
        self.db = db
        self.supervisor = supervisor
        self.router = router ?? NotificationRouter()
        self.accountUsage = accountUsage ?? AccountUsageModel()
        self.sleepGuard = sleepGuard ?? SleepGuard()
        self.quitter = quitter ?? AppQuit()
        self.releaseNotes = releaseNotes
        self.startup = startup
    }
}
