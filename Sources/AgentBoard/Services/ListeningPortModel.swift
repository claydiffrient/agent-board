import AgentBoardCore
import AgentBoardRuntime
import Darwin
import Foundation
import Observation

/// How a listening socket got the name it carries.
enum PortOwnership: String, Sendable, Equatable, CaseIterable {
    /// The parent chain reaches a session running right now.
    case liveSession
    /// The parent chain reaches the project's shell console — a human typing `npm run dev`.
    case shellConsole
    /// The chain is broken and only the pid ledger names the owner. The dev server whose session
    /// ended an hour ago: the row a human currently finds with `lsof -i :3000` and guesswork.
    case orphaned
    /// Nothing names it. Pid and command are all there is.
    case unattributed
}

/// One row the port panel renders without deciding anything.
struct AttributedPort: Identifiable, Sendable, Equatable {
    let port: Int
    let pid: pid_t
    let command: String
    let ownership: PortOwnership
    let sessionId: String?
    let projectId: String?
    let projectName: String?
    let taskTitle: String?

    var id: String { "\(pid):\(port)" }
}

/// Which of the board's processes a pid belongs to. Encoded into the opaque owner string the sweep
/// carries, because the sweep attributes to a key and deliberately never interprets one.
enum PortOwnerKey: Equatable {
    case session(String)
    case shellConsole(projectId: String)

    private static let shellPrefix = "shell:"

    var encoded: String {
        switch self {
        case .session(let id): return id
        case .shellConsole(let projectId): return Self.shellPrefix + projectId
        }
    }

    init(encoded: String) {
        if encoded.hasPrefix(Self.shellPrefix) {
            self = .shellConsole(projectId: String(encoded.dropFirst(Self.shellPrefix.count)))
        } else {
            self = .session(encoded)
        }
    }
}

/// The listening ports Agent Board's processes hold, held in memory and refreshed on a schedule.
///
/// Live system state, so nothing here is persisted as board data and nothing here writes to the
/// database — `PIDSessionLedger` is the one thing that outlives the process, and it is a file.
///
/// One sweep feeds both surfaces: `ports` is the global list for the sidebar panel and
/// `ports(inProject:)` filters the same array for a project's Status pane. Two stores sweeping
/// independently would double the cost and disagree with each other between ticks.
///
/// **Never raises a notification or a badge.** A listening port is information, not an attention
/// signal, which is also why this is off the 5s metering tick: a sweep is real work.
@MainActor
@Observable
final class ListeningPortModel {
    private(set) var ports: [AttributedPort] = []
    private(set) var sweptAt: Date?
    private(set) var isSweeping = false
    /// Row ids with a stop in flight.
    private(set) var stopping: Set<String> = []
    /// Port number -> what went wrong, for a port whose process outlived the escalation or whose
    /// stop was refused.
    ///
    /// Keyed by the port rather than by the row id, which is `(pid, port)`. A supervisor that
    /// respawns under a new pid produces a new row id, and a message keyed on the old one would be
    /// pruned by the refresh — leaving a port that was never released looking like a clean stop.
    private(set) var stopFailures: [Int: String] = [:]

    /// Hourly, on the wall clock. `Task.sleep(for:)` measures on `ContinuousClock`, which keeps
    /// running through a system suspend, so a lid closed for three hours wakes straight into a
    /// sweep. That is correct rather than accidental: `AwakeClock` exists to stop sleeping minutes
    /// counting against a worker's budget, and sleeping minutes genuinely do make this list stale —
    /// processes exit and sockets close while the machine is away.
    static let refreshInterval: Duration = .seconds(60 * 60)

    @ObservationIgnored private let sessions: SessionStore
    @ObservationIgnored private let projects: ProjectStore
    @ObservationIgnored private let ledger: PIDSessionLedger
    @ObservationIgnored private let agentPIDs: @Sendable () async -> [pid_t: String]
    @ObservationIgnored private let shellConsolePIDs: @MainActor () -> [String: pid_t]
    @ObservationIgnored private let boardServerPort: @MainActor () -> Int?
    @ObservationIgnored private let sweep: @Sendable (_ owners: [pid_t: String], _ remembered: [PIDIdentity: String], _ boardServerPort: Int?) -> PortSweepResult
    @ObservationIgnored private let stopper: @Sendable (_ port: Int, _ pid: pid_t, _ boardServerPort: Int?, _ protected: Set<pid_t>) async throws -> PortStopReport
    @ObservationIgnored private var inFlight: _Concurrency.Task<Void, Never>?

    init(
        db: AppDatabase,
        ledger: PIDSessionLedger = PIDSessionLedger(url: PIDSessionLedger.defaultURL()),
        boardServerPort: @escaping @MainActor () -> Int?,
        shellConsolePIDs: @escaping @MainActor () -> [String: pid_t],
        agentPIDs: @escaping @Sendable () async -> [pid_t: String] = ListeningPortModel.claudeAgentPIDs,
        sweep: @escaping @Sendable ([pid_t: String], [PIDIdentity: String], Int?) -> PortSweepResult = {
            ListeningPortSweep.sweepResult(sessionPIDs: $0, remembered: $1, boardServerPort: $2)
        },
        stopper: @escaping @Sendable (Int, pid_t, Int?, Set<pid_t>) async throws -> PortStopReport = {
            try await PortStopper().stop(port: $0, pid: $1, boardServerPort: $2, protected: $3)
        }
    ) {
        sessions = SessionStore(db)
        projects = ProjectStore(db)
        self.ledger = ledger
        self.boardServerPort = boardServerPort
        self.shellConsolePIDs = shellConsolePIDs
        self.agentPIDs = agentPIDs
        self.sweep = sweep
        self.stopper = stopper
    }

    /// The hourly background refresh. Sweeps once on entry so a launch does not wait an hour.
    func run() async {
        while !_Concurrency.Task.isCancelled {
            await refreshAndWait()
            try? await _Concurrency.Task.sleep(for: Self.refreshInterval)
        }
    }

    /// The on-demand entry point: the refresh button the panel adds, and the panel opening. Returns
    /// immediately; the sweep runs off the main thread.
    func refresh() {
        started()
    }

    /// The same refresh, awaited. A caller that already has one in flight joins it rather than
    /// starting a second sweep.
    func refreshAndWait() async {
        await started().value
    }

    func ports(inProject projectId: String) -> [AttributedPort] {
        ports.filter { $0.projectId == projectId }
    }

    func stopFailure(for port: AttributedPort) -> String? { stopFailures[port.port] }

    func isStopping(_ port: AttributedPort) -> Bool { stopping.contains(port.id) }

    /// Hangs up the process group holding `port`, then sweeps again so the row goes rather than
    /// lingering until the hourly refresh.
    ///
    /// A row whose socket survives the escalation keeps its place and carries the reason: dropping
    /// it would claim a stop that did not happen, and the human would find the port again with
    /// `lsof` an hour later.
    func stop(_ port: AttributedPort) async {
        guard stopping.insert(port.id).inserted else { return }
        defer { stopping.remove(port.id) }
        stopFailures[port.port] = nil

        let board = boardServerPort()
        let protected = await protectedPIDs()
        do {
            let report = try await stopper(port.port, port.pid, board, protected)
            if report.outcome == .stillListening {
                stopFailures[port.port] = "Still listening after SIGKILL"
            }
        } catch let refusal as PortStopRefusal {
            stopFailures[port.port] = Self.message(for: refusal)
        } catch {
            stopFailures[port.port] = error.localizedDescription
        }
        await refreshAndWait()
    }

    static func message(for refusal: PortStopRefusal) -> String {
        switch refusal {
        case .boardServerPort:
            return "Agent Board's own port — refused"
        case .notListening:
            return "Nothing is listening there any more"
        }
    }

    /// Every pid whose process group a stop must never signal: the board itself, every `claude`
    /// session host the registry lists, and every shell console's shell.
    ///
    /// Read afresh rather than cached from the last sweep — an hour-old set would protect a pid the
    /// system has since recycled and leave a session started since then unprotected.
    private func protectedPIDs() async -> Set<pid_t> {
        var protected: Set<pid_t> = [
            ProcessInfo.processInfo.processIdentifier,
            getpgrp(),
        ]
        protected.formUnion(await agentPIDs().keys)
        protected.formUnion(shellConsolePIDs().values.filter { $0 > 0 })
        return protected
    }

    @discardableResult
    private func started() -> _Concurrency.Task<Void, Never> {
        if let inFlight { return inFlight }
        isSweeping = true
        let task = _Concurrency.Task { [weak self] in
            defer { self?.finished() }
            await self?.perform()
        }
        inFlight = task
        return task
    }

    private func finished() {
        inFlight = nil
        isSweeping = false
    }

    private func perform() async {
        var owners = await agentPIDs()
        for (projectId, pid) in shellConsolePIDs() where pid > 0 {
            owners[pid] = PortOwnerKey.shellConsole(projectId: projectId).encoded
        }
        let port = boardServerPort()
        let ledger = ledger
        let sweep = sweep
        let result = await _Concurrency.Task.detached(priority: .utility) {
            let result = sweep(owners, ledger.remembered(), port)
            ledger.record(attributions: result.attributions, liveIdentities: result.liveIdentities)
            return result
        }.value
        ports = resolve(result.ports)
        let present = Set(ports.map(\.port))
        stopFailures = stopFailures.filter { present.contains($0.key) }
        sweptAt = .now
    }

    /// Joins each row against the stores at publish time. The session and project rows are read,
    /// never copied into this type — an ended session's task title comes from `agent_session` and
    /// `task`, which nothing deletes, so an orphan keeps its title for as long as those rows do.
    private func resolve(_ swept: [ListeningPort]) -> [AttributedPort] {
        let keys = swept.compactMap { $0.sessionId.map(PortOwnerKey.init(encoded:)) }
        let sessionIds = keys.compactMap { key -> String? in
            if case .session(let id) = key { return id }
            return nil
        }
        let names = (try? sessions.names(of: sessionIds)) ?? [:]
        let projectNames = ((try? projects.list()) ?? []).reduce(into: [String: String]()) {
            $0[$1.id] = $1.name
        }

        return swept.map { row in
            guard let encoded = row.sessionId else {
                return AttributedPort(
                    port: row.port, pid: row.pid, command: row.command,
                    ownership: .unattributed, sessionId: nil,
                    projectId: nil, projectName: nil, taskTitle: nil
                )
            }
            let orphaned = row.source == .ledger
            switch PortOwnerKey(encoded: encoded) {
            case .session(let id):
                let named = names[id]
                return AttributedPort(
                    port: row.port, pid: row.pid, command: row.command,
                    ownership: orphaned ? .orphaned : .liveSession,
                    sessionId: id,
                    projectId: named?.projectId,
                    projectName: named?.projectName,
                    taskTitle: named?.taskTitle
                )
            case .shellConsole(let projectId):
                return AttributedPort(
                    port: row.port, pid: row.pid, command: row.command,
                    ownership: orphaned ? .orphaned : .shellConsole,
                    sessionId: nil,
                    projectId: projectId,
                    projectName: projectNames[projectId],
                    taskTitle: nil
                )
            }
        }
    }

    /// `agent_session` stores no pid, so the live worker and orchestrator pids come from the claude
    /// registry. A session it lists without one has no resident process to attribute anything to.
    nonisolated static let claudeAgentPIDs: @Sendable () async -> [pid_t: String] = {
        guard let listed = try? await BackgroundSessionRuntime().listSessions() else { return [:] }
        return listed.reduce(into: [pid_t: String]()) { result, info in
            guard let pid = info.pid, pid > 0, let sessionId = info.sessionId else { return }
            result[pid_t(pid)] = PortOwnerKey.session(sessionId).encoded
        }
    }
}
