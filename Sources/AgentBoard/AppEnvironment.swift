import AgentBoardCore
import Observation

@Observable
@MainActor
final class AppEnvironment {
    let db: AppDatabase
    let supervisor: any WorkerSupervising

    init(db: AppDatabase, supervisor: any WorkerSupervising) {
        self.db = db
        self.supervisor = supervisor
    }
}
