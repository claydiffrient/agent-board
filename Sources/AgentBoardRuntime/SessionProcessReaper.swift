import Darwin
import Foundation

/// What identifies the processes one ended worker session started (SPEC §8.5). No group or session
/// kill reaches them: every Bash tool command leads its own session.
public struct SessionProcessScope: Sendable, Equatable {
    /// The host's descendants, read while it was still alive.
    public var tree: Set<PIDIdentity>
    /// The session's own checkout; nil for a shared checkout, which the human works in too.
    public var worktree: String?
    public var startedAtMicros: Int64
    /// Every other live `claude` host. Neither they, their ancestors nor their descendants are signalled.
    public var otherHosts: Set<pid_t>

    public init(tree: Set<PIDIdentity>, worktree: String?, startedAtMicros: Int64, otherHosts: Set<pid_t>) {
        self.tree = tree
        self.worktree = worktree
        self.startedAtMicros = startedAtMicros
        self.otherHosts = otherHosts
    }
}

public enum SessionProcessReaper {
    /// Captured before `claude stop`, while the host still parents its children.
    public static func tree(ofHost host: pid_t) async -> Set<PIDIdentity> {
        let table = ProcessTable.current()
        return Set(table.descendants(of: host).compactMap(table.identity(of:)))
    }

    /// The captured tree still alive, every orphan the session left in its worktree, and their
    /// current descendants, minus anything protected (SPEC §8.5).
    static func targets(_ scope: SessionProcessScope, table: ProcessTable) -> Set<PIDIdentity> {
        var roots = Set(scope.tree.filter { table.identity(of: $0.pid) == $0 }.map(\.pid))
        if let worktree = scope.worktree.map(canonical) {
            for (pid, entry) in table.entries where entry.ppid == 1 && entry.startedAtMicros >= scope.startedAtMicros {
                guard let fact = LibProc.facts(pid), !fact.hasControllingTerminal,
                      let cwd = fact.cwd.map(canonical), cwd == worktree || cwd.hasPrefix(worktree + "/")
                else { continue }
                roots.insert(pid)
            }
        }
        var all = roots
        for root in roots { all.formUnion(table.descendants(of: root)) }

        var protected: Set<pid_t> = [getpid()]
        protected.formUnion(table.ancestors(of: getpid()))
        for host in scope.otherHosts where table.entries[host] != nil {
            protected.insert(host)
            protected.formUnion(table.ancestors(of: host))
            protected.formUnion(table.descendants(of: host))
        }
        return Set(all.subtracting(protected).filter { LibProc.facts($0)?.isClaude != true }.compactMap(table.identity(of:)))
    }

    /// SIGTERM, then SIGKILL whatever is still there after `grace`. Returns what survived both.
    /// Each round re-reads the table, so a child forked in between is caught and a reused pid is not.
    @discardableResult
    public static func reap(
        _ scope: SessionProcessScope,
        grace: Duration = .seconds(2),
        poll: Duration = .milliseconds(50)
    ) async -> Set<PIDIdentity> {
        var signalled: Set<PIDIdentity> = []
        for signal in [SIGTERM, SIGKILL] {
            let table = ProcessTable.current()
            let current = targets(scope, table: table).union(signalled.filter { table.identity(of: $0.pid) == $0 })
            guard !current.isEmpty else { return [] }
            for target in current { kill(target.pid, signal) }
            signalled.formUnion(current)
            let deadline = ContinuousClock.now + grace
            while ContinuousClock.now < deadline, !alive(signalled).isEmpty {
                try? await _Concurrency.Task.sleep(for: poll)
            }
        }
        return alive(signalled)
    }

    private static func alive(_ identities: Set<PIDIdentity>) -> Set<PIDIdentity> {
        identities.filter { identity in
            LibProc.bsdInfo(identity.pid).map { LibProc.startedAtMicros($0) == identity.startedAtMicros } ?? false
        }
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}

public struct ProcessFacts: Sendable, Equatable {
    public var cwd: String?
    public var hasControllingTerminal: Bool
    public var isClaude: Bool

    public init(cwd: String?, hasControllingTerminal: Bool, isClaude: Bool) {
        self.cwd = cwd
        self.hasControllingTerminal = hasControllingTerminal
        self.isClaude = isClaude
    }
}

extension ProcessTable {
    public func descendants(of root: pid_t) -> Set<pid_t> {
        var children: [pid_t: [pid_t]] = [:]
        for (pid, entry) in entries { children[entry.ppid, default: []].append(pid) }
        var found: Set<pid_t> = []
        var frontier = children[root] ?? []
        while let pid = frontier.popLast() {
            guard pid != root, found.insert(pid).inserted else { continue }
            frontier += children[pid] ?? []
        }
        return found
    }

    public func ancestors(of pid: pid_t) -> Set<pid_t> {
        var found: Set<pid_t> = []
        var current = pid
        while let parent = entries[current]?.ppid, parent > 1, found.insert(parent).inserted {
            current = parent
        }
        return found
    }
}

extension LibProc {
    static func facts(_ pid: pid_t) -> ProcessFacts? {
        guard let info = bsdInfo(pid) else { return nil }
        return ProcessFacts(
            cwd: cwd(pid),
            hasControllingTerminal: info.e_tdev != UInt32(bitPattern: -1),
            isClaude: isClaude(pid, info: info)
        )
    }

    static func cwd(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return path.isEmpty ? nil : path
    }

    /// The native installer runs `~/.local/share/claude/versions/<version>`, so the accounting name
    /// is a version number; the executable path is what says it is claude.
    static func isClaude(_ pid: pid_t, info: proc_bsdinfo) -> Bool {
        if command(info) == "claude" { return true }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        let path = String(cString: buffer)
        return path.contains("/claude/versions/") || path.hasSuffix("/claude") || path.contains("/claude-code/")
    }
}
