import AgentBoardCore
import Observation

@Observable
@MainActor
final class AppEnvironment {
    let db: AppDatabase
    let supervisor: any WorkerSupervising
    let router: NotificationRouter
    /// Nil in the previews and in tests that do not wire a supervisor; every port surface treats
    /// its absence as an empty list rather than an error.
    let listeningPorts: ListeningPortModel?

    init(
        db: AppDatabase,
        supervisor: any WorkerSupervising,
        router: NotificationRouter? = nil,
        listeningPorts: ListeningPortModel? = nil
    ) {
        self.db = db
        self.supervisor = supervisor
        self.router = router ?? NotificationRouter()
        self.listeningPorts = listeningPorts
    }
}
