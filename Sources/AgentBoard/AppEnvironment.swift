import AgentBoardCore
import Observation

@Observable
@MainActor
final class AppEnvironment {
    let db: AppDatabase
    let supervisor: any WorkerSupervising
    let router: NotificationRouter
    let releaseNotes: ReleaseNotesAnnouncer
    /// `supervisor.start()`, so a launch-time screen can wait for the server bind, the stale-lock
    /// sweep and the worktree-root migration to finish. Nil everywhere the supervisor is a stub.
    let startup: _Concurrency.Task<Void, Never>?

    init(
        db: AppDatabase,
        supervisor: any WorkerSupervising,
        router: NotificationRouter? = nil,
        releaseNotes: ReleaseNotesAnnouncer = ReleaseNotesAnnouncer(),
        startup: _Concurrency.Task<Void, Never>? = nil
    ) {
        self.db = db
        self.supervisor = supervisor
        self.router = router ?? NotificationRouter()
        self.releaseNotes = releaseNotes
        self.startup = startup
    }
}
