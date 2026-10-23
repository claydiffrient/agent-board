import AgentBoardCore
import AgentBoardRuntime
import Darwin
import Foundation

/// The terminal windows' processes — worktree shells and `claude attach` — which no service
/// holds, so each `TerminalHostView` registers its own child while it runs (SPEC §8.7).
@MainActor
final class TerminalProcessRegistry {
    private var owners: [pid_t: ProcessOwner] = [:]

    func register(_ pid: pid_t, owner: ProcessOwner) {
        guard pid > 0 else { return }
        owners[pid] = owner
    }

    func unregister(_ pid: pid_t) {
        owners[pid] = nil
    }

    var roots: [InventoryRoot] {
        owners.map { InventoryRoot(pid: $0.key, owner: $0.value) }
    }
}

/// The session roots, rebuilt at most every `ttl`: `claude agents` launches a process, which a
/// 2s sample would otherwise pay every time (SPEC §8.7).
actor SessionProcessRoots {
    static let ttl: Duration = .seconds(10)

    private let db: AppDatabase
    private let listing: @Sendable () async -> [AgentInfo]
    private var cached: (roots: [InventoryRoot], at: ContinuousClock.Instant)?

    init(
        db: AppDatabase,
        listing: @escaping @Sendable () async -> [AgentInfo] = {
            (try? await BackgroundSessionRuntime().listSessions()) ?? []
        }
    ) {
        self.db = db
        self.listing = listing
    }

    func roots() async -> [InventoryRoot] {
        if let cached, ContinuousClock.now - cached.at < Self.ttl { return cached.roots }
        let listed = await listing()
        let store = SessionStore(db)
        let rows = ((try? ProjectStore(db).list()) ?? []).flatMap { (try? store.all(projectId: $0.id)) ?? [] }
        let roots = SessionInventoryRoots.roots(listing: listed, sessions: rows) {
            FileManager.default.fileExists(atPath: $0)
        }
        cached = (roots, .now)
        return roots
    }
}

extension LiveProcessSampler {
    /// Every root SPEC §8.7 lists: session hosts and ended sessions' worktrees, the supervisor's
    /// consoles, the terminal windows, and the Ports sweep's last rows.
    @MainActor
    static func board(
        db: AppDatabase,
        supervisor: WorkerSupervisor,
        terminals: TerminalProcessRegistry,
        ports: ListeningPortModel
    ) -> LiveProcessSampler {
        let sessions = SessionProcessRoots(db: db)
        return LiveProcessSampler(
            roots: {
                let consoles = await MainActor.run { supervisor.consoleProcessRoots() + terminals.roots }
                return await sessions.roots() + consoles
            },
            ports: {
                await MainActor.run {
                    ports.ports.map {
                        ListeningPort(port: $0.port, pid: $0.pid, command: $0.command, sessionId: $0.sessionId)
                    }
                }
            }
        )
    }
}
