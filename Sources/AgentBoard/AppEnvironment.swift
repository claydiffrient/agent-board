import AgentBoardCore
import Observation

@Observable
@MainActor
final class AppEnvironment {
    let db: AppDatabase
    let supervisor: any WorkerSupervising
    let router: NotificationRouter

    init(db: AppDatabase, supervisor: any WorkerSupervising, router: NotificationRouter? = nil) {
        self.db = db
        self.supervisor = supervisor
        self.router = router ?? NotificationRouter()
    }
}
