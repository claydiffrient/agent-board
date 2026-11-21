import Darwin
import Foundation

/// What `WorktreeManager.remove` did to the processes still working in a worktree (SPEC §3.1
/// "Removing a worktree"). Nothing here decides whether the worktree goes.
public struct WorktreeProcessStop: Sendable, Equatable {
    public struct Process: Sendable, Equatable {
        public var pid: pid_t
        public var command: String

        public init(pid: pid_t, command: String) {
            self.pid = pid
            self.command = command
        }
    }

    public var stopped: [Process] = []
    /// Has a controlling terminal and is no Agent Board host's, so a human may be using it; never signaled.
    public var kept: [Process] = []
    public var failures: [String] = []

    public init(stopped: [Process] = [], kept: [Process] = [], failures: [String] = []) {
        self.stopped = stopped
        self.kept = kept
        self.failures = failures
    }

    public func notice(for worktree: URL) -> String? {
        func list(_ processes: [Process]) -> String {
            processes.map { "\($0.command) (pid \($0.pid))" }.joined(separator: ", ")
        }
        var lines: [String] = []
        if !stopped.isEmpty {
            lines.append("Stopped processes still running in \(worktree.path) before removing it: \(list(stopped)).")
        }
        if !kept.isEmpty {
            lines.append("Left running in \(worktree.path) because they have a terminal: \(list(kept)).")
        }
        lines += failures
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

enum WorktreeProcessStopper {
    static let termGrace: UInt64 = 5_000_000_000
    static let poll: useconds_t = 50_000

    /// SIGTERM to every process of this user whose cwd is `worktree` or inside it, then SIGKILL to
    /// whatever outlives `grace` on `CLOCK_UPTIME_RAW` (SPEC §3.1). One with a controlling terminal
    /// is kept unless it is one of `agentHosts` or descends from one.
    static func stop(
        in worktree: URL,
        agentHosts: Set<PIDIdentity> = [],
        grace: UInt64 = termGrace,
        facts: (pid_t) -> ProcessFacts? = LibProc.facts
    ) -> WorktreeProcessStop {
        var report = WorktreeProcessStop()
        guard proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0) > 0 else {
            report.failures.append(
                "Could not list processes to stop in \(worktree.path): \(String(cString: strerror(errno)))."
            )
            return report
        }
        let table = ProcessTable.current()
        let root = worktree.standardizedFileURL.resolvingSymlinksInPath().path
        let protected = table.ancestors(of: getpid()).union([getpid()])
        let user = getuid()
        var agentTree: Set<pid_t> = []
        for host in agentHosts where table.identity(of: host.pid) == host {
            agentTree.insert(host.pid)
            agentTree.formUnion(table.descendants(of: host.pid))
        }

        var targets: [PIDIdentity: String] = [:]
        for (pid, entry) in table.entries.sorted(by: { $0.key < $1.key })
        where !protected.contains(pid) && entry.uid == user {
            guard let fact = facts(pid), let cwd = fact.cwd else { continue }
            let resolved = URL(fileURLWithPath: cwd).standardizedFileURL.resolvingSymlinksInPath().path
            guard resolved == root || resolved.hasPrefix(root + "/") else { continue }
            if fact.hasControllingTerminal, !agentTree.contains(pid) {
                report.kept.append(.init(pid: pid, command: entry.command))
            } else {
                targets[PIDIdentity(pid: pid, startedAtMicros: entry.startedAtMicros)] = entry.command
            }
        }
        guard !targets.isEmpty else { return report }

        var signaled: [PIDIdentity: String] = [:]
        for (target, command) in targets {
            if kill(target.pid, SIGTERM) == 0 || errno == ESRCH {
                signaled[target] = command
            } else {
                report.failures.append(
                    "Could not stop \(command) (pid \(target.pid)) in \(worktree.path): \(String(cString: strerror(errno)))."
                )
            }
        }
        let deadline = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + grace
        while clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < deadline, signaled.keys.contains(where: isAlive) {
            usleep(poll)
        }
        for target in signaled.keys where isAlive(target) {
            if kill(target.pid, SIGKILL) != 0, errno != ESRCH {
                report.failures.append(
                    "Could not kill \(signaled[target] ?? "") (pid \(target.pid)) in \(worktree.path): "
                        + "\(String(cString: strerror(errno)))."
                )
            }
        }
        report.stopped = signaled.map { .init(pid: $0.key.pid, command: $0.value) }.sorted { $0.pid < $1.pid }
        return report
    }

    /// A zombie has exited; only its parent's wait is outstanding. A reused pid is a different process.
    private static func isAlive(_ identity: PIDIdentity) -> Bool {
        guard let info = LibProc.bsdInfo(identity.pid) else { return false }
        return LibProc.startedAtMicros(info) == identity.startedAtMicros && info.pbi_status != UInt32(SZOMB)
    }
}
