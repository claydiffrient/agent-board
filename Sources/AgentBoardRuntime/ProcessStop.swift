import Darwin
import Foundation

/// Why the process view refused a stop. Nothing was signalled (SPEC §8.7).
public enum ProcessStopRefusal: Error, Equatable, Sendable {
    /// Agent Board's own pid or one of its ancestors.
    case agentBoard(pid_t)
    /// A `claude` process that is not the row's own session host: another session's host, or a
    /// host the registry did not list, at or below the row.
    case sessionHost(pid_t)
    /// An orchestrator's or the Coordinator's host. It runs in its console and is ended there.
    case consoleHost
    /// The row's process is not in the current inventory.
    case notInInventory
    /// The pid now names another process, or none, than the one the row drew.
    case identityChanged
    case otherUser(pid_t)
}

public enum ProcessStopPlan: Equatable, Sendable {
    /// A worker's or reviewer's host. Goes through the session Stop, which reaps its tree (§8.5).
    case session(String)
    case tree(ProcessTreeStop)
}

/// A non-host process and its descendants, read from one process table.
public struct ProcessTreeStop: Equatable, Sendable {
    public let root: PIDIdentity
    /// The root and every descendant.
    public let members: Set<PIDIdentity>
    /// The root's own process group, when it leads one that holds nothing protected. Signalling it
    /// reaches descendants already reparented to launchd, which the parent walk no longer finds.
    public let group: pid_t?
    /// What a later round's re-read must never add: the board, its ancestors and group, and every host.
    public let protected: Set<pid_t>
    public let uid: uid_t

    public init(root: PIDIdentity, members: Set<PIDIdentity>, group: pid_t?, protected: Set<pid_t>, uid: uid_t) {
        self.root = root
        self.members = members
        self.group = group
        self.protected = protected
        self.uid = uid
    }
}

public enum ProcessStopPlanner {
    /// - Parameters:
    ///   - row: the identity the row was drawn with.
    ///   - hosts: every `claude` session host the registry lists, pid to session id.
    public static func plan(
        _ row: PIDIdentity,
        inventory: ProcessInventory,
        table: ProcessTable,
        hosts: [pid_t: String],
        isClaude: (pid_t) -> Bool,
        board: pid_t,
        uid: uid_t
    ) throws -> ProcessStopPlan {
        let pid = row.pid
        if pid == board || table.ancestors(of: board).contains(pid) { throw ProcessStopRefusal.agentBoard(pid) }
        guard let process = inventory.processes.first(where: { $0.identity == row }) else {
            throw ProcessStopRefusal.notInInventory
        }
        guard table.identity(of: pid) == row else { throw ProcessStopRefusal.identityChanged }
        guard table.entries[pid]?.uid == uid else { throw ProcessStopRefusal.otherUser(pid) }

        let owner = process.owner
        if process.parent == nil, let sessionId = owner.sessionId {
            switch owner.role {
            case .worker, .reviewer:
                if hosts[pid] == sessionId { return .session(sessionId) }
            case .orchestrator, .coordinator:
                if hosts[pid] != nil || isClaude(pid) { throw ProcessStopRefusal.consoleHost }
            case .humanShell, .agentBoard:
                break
            }
        }
        if hosts[pid] != nil || isClaude(pid) { throw ProcessStopRefusal.sessionHost(pid) }

        let descendants = table.descendants(of: pid)
        for member in descendants.sorted() {
            if member == board || hosts[member] != nil || isClaude(member) {
                throw ProcessStopRefusal.sessionHost(member)
            }
            guard table.entries[member]?.uid == uid else { throw ProcessStopRefusal.otherUser(member) }
        }

        var protected = Set(hosts.keys).union([board]).union(table.ancestors(of: board))
        if let boardGroup = table.entries[board]?.pgid, boardGroup > 1 { protected.insert(boardGroup) }
        var group: pid_t?
        if PortStopPlanner.scope(listener: pid, table: table, protected: protected) == .processGroup(pid) {
            let members = table.members(ofGroup: pid)
            let safe = members.allSatisfy { !protected.contains($0) && !isClaude($0) && table.entries[$0]?.uid == uid }
            if safe { group = pid }
        }
        return .tree(ProcessTreeStop(
            root: row,
            members: Set(([pid] + descendants).compactMap(table.identity(of:))),
            group: group,
            protected: protected,
            uid: uid
        ))
    }

    public static func isClaude(_ pid: pid_t) -> Bool {
        LibProc.facts(pid)?.isClaude == true
    }
}

public struct ProcessTreeStopReport: Equatable, Sendable {
    public let signalled: Set<PIDIdentity>
    public let escalated: Bool
    /// Still alive after SIGKILL.
    public let survivors: Set<PIDIdentity>

    public init(signalled: Set<PIDIdentity>, escalated: Bool, survivors: Set<PIDIdentity>) {
        self.signalled = signalled
        self.escalated = escalated
        self.survivors = survivors
    }
}

extension PortStopper {
    /// SIGTERM to the tree, then SIGKILL to whatever is left after `grace`. Each round re-reads the
    /// table, so a child forked in between is caught and a reused pid is not signalled.
    public func stop(_ tree: ProcessTreeStop) async -> ProcessTreeStopReport {
        var signalled: Set<PIDIdentity> = []
        var escalated = false
        for signal in [SIGTERM, SIGKILL] {
            let table = ProcessTable.current()
            let current = Self.targets(tree, signalled: signalled, table: table)
            guard !current.isEmpty else { break }
            escalated = signal == SIGKILL
            if let group = tree.group {
                let members = table.members(ofGroup: group)
                if !members.isEmpty, members.allSatisfy({ pid in current.contains { $0.pid == pid } }) {
                    kill(-group, signal)
                }
            }
            for target in current { kill(target.pid, signal) }
            signalled.formUnion(current)
            let deadline = ContinuousClock.now + grace
            while ContinuousClock.now < deadline, !Self.alive(signalled).isEmpty {
                try? await _Concurrency.Task.sleep(for: poll)
            }
        }
        return ProcessTreeStopReport(signalled: signalled, escalated: escalated, survivors: Self.alive(signalled))
    }

    static func targets(_ tree: ProcessTreeStop, signalled: Set<PIDIdentity>, table: ProcessTable) -> Set<PIDIdentity> {
        let known = tree.members.union(signalled).filter { table.identity(of: $0.pid) == $0 }
        var found = known
        for member in known {
            for pid in table.descendants(of: member.pid)
            where !tree.protected.contains(pid) && table.entries[pid]?.uid == tree.uid && !ProcessStopPlanner.isClaude(pid) {
                if let identity = table.identity(of: pid) { found.insert(identity) }
            }
        }
        return found
    }

    /// A zombie is dead: its parent has yet to reap it, and no signal reaches it.
    private static func alive(_ identities: Set<PIDIdentity>) -> Set<PIDIdentity> {
        identities.filter { identity in
            guard let info = LibProc.bsdInfo(identity.pid) else { return false }
            return info.pbi_status != SZOMB && LibProc.startedAtMicros(info) == identity.startedAtMicros
        }
    }
}
