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

    init(
        db: AppDatabase, supervisor: any WorkerSupervising, router: NotificationRouter? = nil,
        accountUsage: AccountUsageModel? = nil, sleepGuard: SleepGuard? = nil
    ) {
        self.db = db
        self.supervisor = supervisor
        self.router = router ?? NotificationRouter()
        self.accountUsage = accountUsage ?? AccountUsageModel()
        self.sleepGuard = sleepGuard ?? SleepGuard()
    }
}
