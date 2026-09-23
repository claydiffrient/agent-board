import Darwin
import Foundation

/// Why a stop was refused before any signal was sent.
public enum PortStopRefusal: Error, Equatable {
    /// The board's own port. Every worker's MCP connection and every hook round trip goes through
    /// it, so stopping it stops every agent on the machine. The sweep already excludes it; this is
    /// the second wall, checked before anything else and before the process table is even read.
    case boardServerPort(Int)
    /// Nothing is listening on that port under that pid any more. The row was stale, not stopped.
    case notListening(port: Int, pid: pid_t)
}

/// What the stop will actually signal.
///
/// `kill(-n, …)` addresses the process group whose id is `n`, not "the group containing pid n", so
/// a listener that is not its own group leader cannot be addressed by its own pid. Measured on a
/// real `npm run dev` under an interactive shell: the listening `node` had pgid equal to its parent
/// `npm`, and the shell sat in a third group of its own.
public enum PortStopScope: Equatable, Sendable {
    /// The pgid to signal. The group leader is the listener itself or one of its ancestors, so the
    /// group cannot reach sideways into a tree the human did not ask about.
    case processGroup(pid_t)
    /// The group was not safe to signal — its leader is off the listener's ancestor chain, or it is
    /// a process the board runs long-term — so only the listener is signalled. A supervisor above
    /// it may respawn; that is the price of not killing the supervisor too.
    case processOnly(pid_t)

    /// What `kill(2)` is handed; negative addresses the group.
    public var signalTarget: pid_t {
        switch self {
        case .processGroup(let pgid): return -pgid
        case .processOnly(let pid): return pid
        }
    }
}

public enum PortStopOutcome: String, Equatable, Sendable {
    case stopped
    /// The port was still held after SIGKILL. The row stays and says so — dropping it would claim
    /// a stop that did not happen.
    case stillListening
}

public struct PortStopReport: Equatable, Sendable {
    public let scope: PortStopScope
    public let escalated: Bool
    public let outcome: PortStopOutcome

    public init(scope: PortStopScope, escalated: Bool, outcome: PortStopOutcome) {
        self.scope = scope
        self.escalated = escalated
        self.outcome = outcome
    }
}

/// Chooses what a stop may signal, from the process table alone.
public enum PortStopPlanner {
    /// - Parameter protected: pids whose process group must never be signalled — the board itself,
    ///   every `claude` session host, and every shell console's shell. Signalling one of those
    ///   groups is how a stop button beside a dev server ends up killing an agent.
    public static func scope(
        listener pid: pid_t,
        table: ProcessTable,
        protected: Set<pid_t>
    ) -> PortStopScope {
        guard let entry = table.entries[pid] else { return .processOnly(pid) }
        let pgid = entry.pgid
        guard pgid > 1, !protected.contains(pgid) else { return .processOnly(pid) }
        if pgid == pid { return .processGroup(pgid) }
        guard table.isAncestor(pgid, of: pid) else { return .processOnly(pid) }
        // A group whose leader is an ancestor still reaches every sibling under that ancestor, so
        // it must not straddle anything the board runs long-term.
        guard protected.isDisjoint(with: table.members(ofGroup: pgid)) else { return .processOnly(pid) }
        return .processGroup(pgid)
    }
}

/// Stops whatever holds a listening port: SIGHUP to the chosen scope, SIGKILL after a grace
/// (SPEC §10).
///
/// SIGHUP rather than SIGTERM because that is what a closing terminal window sends and what a
/// supervisor like `npm run dev` propagates to its children; `ShellConsole.hangUp()` established
/// the same pattern for the shell console. The escalation is a backstop rather than the common
/// path — SIGHUP alone ended `/bin/sh` in 0.752s when that was measured.
public struct PortStopper: Sendable {
    public let grace: Duration
    public let poll: Duration

    public init(grace: Duration = .seconds(2), poll: Duration = .milliseconds(50)) {
        self.grace = grace
        self.poll = poll
    }

    public func stop(
        port: Int,
        pid: pid_t,
        boardServerPort: Int?,
        protected: Set<pid_t>
    ) async throws -> PortStopReport {
        guard port != boardServerPort else { throw PortStopRefusal.boardServerPort(port) }

        let table = ProcessTable.current()
        guard ListeningPortSweep.holders(of: port).contains(pid) else {
            throw PortStopRefusal.notListening(port: port, pid: pid)
        }
        let scope = PortStopPlanner.scope(listener: pid, table: table, protected: protected)

        kill(scope.signalTarget, SIGHUP)
        if await waitForRelease(of: port) {
            return PortStopReport(scope: scope, escalated: false, outcome: .stopped)
        }

        kill(scope.signalTarget, SIGKILL)
        let released = await waitForRelease(of: port)
        return PortStopReport(
            scope: scope, escalated: true, outcome: released ? .stopped : .stillListening
        )
    }

    private func waitForRelease(of port: Int) async -> Bool {
        let deadline = ContinuousClock.now + grace
        while ContinuousClock.now < deadline {
            if ListeningPortSweep.holders(of: port).isEmpty { return true }
            try? await _Concurrency.Task.sleep(for: poll)
        }
        return ListeningPortSweep.holders(of: port).isEmpty
    }
}

extension ListeningPortSweep {
    /// Every pid holding a listening TCP socket on `port`. Deliberately not filtered by the board's
    /// own exclusion: this answers "is the socket gone", which a stop has to know regardless.
    public static func holders(of port: Int) -> [pid_t] {
        LibProc.allPIDs().filter { LibProc.listeningTCPPorts(of: $0).contains(port) }
    }
}
