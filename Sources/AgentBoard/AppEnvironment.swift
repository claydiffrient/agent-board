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
    /// Quitting is not `NSApplication.terminate` on its own — see `AppQuitting` — and a test needs
    /// a seam that does not end the test process.
    let quitter: any AppQuitting

    init(
        db: AppDatabase, supervisor: any WorkerSupervising, router: NotificationRouter? = nil,
        accountUsage: AccountUsageModel? = nil, quitter: (any AppQuitting)? = nil
    ) {
        self.db = db
        self.supervisor = supervisor
        self.router = router ?? NotificationRouter()
        self.accountUsage = accountUsage ?? AccountUsageModel()
        self.quitter = quitter ?? AppQuit()
    }
}
