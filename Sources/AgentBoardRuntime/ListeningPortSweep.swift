import Darwin
import Foundation

/// One TCP socket in `LISTEN`, with the Agent Board session it was traced back to.
///
/// `sessionId` is nil for a socket whose parent chain reaches pid 1 or a process the board never
/// launched. That is a result, not a failure: an orphaned dev server is exactly the row a human
/// cannot otherwise see.
public struct ListeningPort: Sendable, Equatable {
    public let port: Int
    public let pid: pid_t
    public let command: String
    /// The owner key the walk landed on, or nil. Callers that own more than one kind of process
    /// encode the kind into the key they pass as `sessionPIDs`; the sweep never interprets it.
    public let sessionId: String?
    /// Nil exactly when `sessionId` is. `.ledger` means the parent chain was already broken and
    /// only a recorded `(pid, start time)` named the owner.
    public let source: PortAttributionSource?

    public init(port: Int, pid: pid_t, command: String, sessionId: String?, source: PortAttributionSource? = nil) {
        self.port = port
        self.pid = pid
        self.command = command
        self.sessionId = sessionId
        self.source = source == nil && sessionId != nil ? .liveChain : source
    }
}

/// How a socket got its owner. The distinction is the whole orphan story: a `.ledger` row is a
/// process whose parent chain no longer reaches anything the board launched.
public enum PortAttributionSource: String, Sendable, Equatable, Codable {
    /// A pid in the live parent chain is one the caller named as an owner.
    case liveChain
    /// The chain led nowhere; a remembered `(pid, start time)` supplied the owner.
    case ledger
}

/// A pid paired with the microsecond its process started.
///
/// The start time is what makes a remembered pid falsifiable. macOS recycles pids, and a ledger
/// that outlives the session it recorded widens that window by hours, so a bare pid would sooner or
/// later hand an unrelated socket someone else's task title.
public struct PIDIdentity: Hashable, Sendable, Codable {
    public let pid: pid_t
    public let startedAtMicros: Int64

    public init(pid: pid_t, startedAtMicros: Int64) {
        self.pid = pid
        self.startedAtMicros = startedAtMicros
    }
}

/// One sweep's rows plus what it learned, which is not the same thing: `attributions` covers every
/// process on an attributed chain, not just the listeners, so a shell that outlives its session
/// still carries the session id when the socket under it is swept again.
public struct PortSweepResult: Sendable, Equatable {
    public let ports: [ListeningPort]
    public let attributions: [PIDIdentity: String]
    /// Every process alive at sweep time. A ledger prunes against it, which is also what makes a
    /// reboot clear the ledger without anything dating entries.
    public let liveIdentities: Set<PIDIdentity>

    public init(ports: [ListeningPort], attributions: [PIDIdentity: String], liveIdentities: Set<PIDIdentity>) {
        self.ports = ports
        self.attributions = attributions
        self.liveIdentities = liveIdentities
    }
}

/// A pid -> (ppid, command) snapshot, built once per sweep so walking every chain stays linear.
public struct ProcessTable: Sendable {
    public struct Entry: Sendable, Equatable {
        public let ppid: pid_t
        public let command: String
        public let startedAtMicros: Int64
        /// The process group this pid belongs to, which is only equal to the pid when it leads one.
        /// `kill(-n, …)` addresses the group whose id is `n`, so a stop has to know this before it
        /// can signal anything wider than a single process.
        public let pgid: pid_t

        public init(ppid: pid_t, command: String, startedAtMicros: Int64 = 0, pgid: pid_t = 0) {
            self.ppid = ppid
            self.command = command
            self.startedAtMicros = startedAtMicros
            self.pgid = pgid
        }
    }

    public let entries: [pid_t: Entry]

    public init(entries: [pid_t: Entry]) {
        self.entries = entries
    }

    public static func current() -> ProcessTable {
        current(pids: LibProc.allPIDs())
    }

    static func current(pids: [pid_t]) -> ProcessTable {
        var entries: [pid_t: Entry] = [:]
        entries.reserveCapacity(pids.count)
        for pid in pids {
            guard let info = LibProc.bsdInfo(pid) else { continue }
            entries[pid] = Entry(
                ppid: pid_t(bitPattern: info.pbi_ppid),
                command: LibProc.command(info),
                startedAtMicros: LibProc.startedAtMicros(info),
                pgid: pid_t(bitPattern: info.pbi_pgid)
            )
        }
        return ProcessTable(entries: entries)
    }

    public func command(of pid: pid_t) -> String {
        entries[pid]?.command ?? ""
    }

    public func identity(of pid: pid_t) -> PIDIdentity? {
        entries[pid].map { PIDIdentity(pid: pid, startedAtMicros: $0.startedAtMicros) }
    }

    public var liveIdentities: Set<PIDIdentity> {
        Set(entries.map { PIDIdentity(pid: $0.key, startedAtMicros: $0.value.startedAtMicros) })
    }

    /// Walks from `pid` upwards until `resolve` answers, returning the answer and every pid walked
    /// through to reach it. The chain is the useful half: recording all of it means a later sweep
    /// can still attribute the socket after any one link dies.
    public func firstOwner<Value>(of pid: pid_t, resolve: (pid_t) -> Value?) -> (value: Value, chain: [pid_t])? {
        var current = pid
        var chain: [pid_t] = []
        var visited: Set<pid_t> = []
        while current > 1, visited.insert(current).inserted {
            chain.append(current)
            if let value = resolve(current) { return (value, chain) }
            guard let parent = entries[current]?.ppid else { return nil }
            current = parent
        }
        return nil
    }

    /// Whether `candidate` appears strictly above `pid` on the parent chain.
    public func isAncestor(_ candidate: pid_t, of pid: pid_t) -> Bool {
        var current = pid
        var visited: Set<pid_t> = []
        while current > 1, visited.insert(current).inserted {
            guard let parent = entries[current]?.ppid else { return false }
            if parent == candidate { return true }
            current = parent
        }
        return false
    }

    /// Every pid in the process group `pgid`, including the leader when it is still alive.
    public func members(ofGroup pgid: pid_t) -> Set<pid_t> {
        Set(entries.filter { $0.value.pgid == pgid }.keys)
    }

    /// The first pid at or above `pid` that `owners` names, or nil when the chain reaches pid 1 or
    /// a pid no longer in the table — which is what a reparented orphan looks like.
    public func owner<Value>(of pid: pid_t, in owners: [pid_t: Value]) -> Value? {
        var current = pid
        var visited: Set<pid_t> = []
        while current > 1, visited.insert(current).inserted {
            if let owner = owners[current] { return owner }
            guard let parent = entries[current]?.ppid else { return nil }
            current = parent
        }
        return nil
    }
}

public enum ListeningPortSweep {
    /// Every listening TCP port on this machine, attributed to a session where the parent chain
    /// reaches one.
    ///
    /// `boardServerPort` is dropped here rather than by a caller: it is the port every worker's MCP
    /// connection and hook round trip uses, and it must never reach a view that offers to kill it.
    public static func sweep(sessionPIDs: [pid_t: String], boardServerPort: Int?) -> [ListeningPort] {
        sweepResult(sessionPIDs: sessionPIDs, boardServerPort: boardServerPort).ports
    }

    /// The same sweep, plus a remembered `(pid, start time) -> owner` map consulted when the parent
    /// chain reaches nothing, and the attributions this sweep learned so a ledger can record them.
    ///
    /// The two owner sources are tried in that order deliberately. The live chain is self-evidently
    /// true; `remembered` is a claim about the past, and it only gets a say once the chain that
    /// could have confirmed it is gone.
    public static func sweepResult(
        sessionPIDs: [pid_t: String],
        remembered: [PIDIdentity: String] = [:],
        boardServerPort: Int?
    ) -> PortSweepResult {
        // One pid list feeds both the parent map and the socket walk, so a socket on a process
        // whose `proc_pidinfo` lookup failed is still reported, just unattributed.
        let pids = LibProc.allPIDs()
        let table = ProcessTable.current(pids: pids)
        var ports: [ListeningPort] = []
        var attributions: [PIDIdentity: String] = [:]
        var seen: Set<PortKey> = []

        for pid in pids {
            for port in LibProc.listeningTCPPorts(of: pid) {
                guard port != boardServerPort else { continue }
                guard seen.insert(PortKey(pid: pid, port: port)).inserted else { continue }
                let attributed = attribute(pid: pid, table: table, sessionPIDs: sessionPIDs, remembered: remembered)
                if let attributed {
                    for walked in attributed.chain {
                        guard let identity = table.identity(of: walked) else { continue }
                        attributions[identity] = attributed.owner
                    }
                }
                ports.append(
                    ListeningPort(
                        port: port,
                        pid: pid,
                        command: table.command(of: pid),
                        sessionId: attributed?.owner,
                        source: attributed?.source
                    )
                )
            }
        }
        return PortSweepResult(
            ports: ports.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) },
            attributions: attributions,
            liveIdentities: table.liveIdentities
        )
    }

    private static func attribute(
        pid: pid_t,
        table: ProcessTable,
        sessionPIDs: [pid_t: String],
        remembered: [PIDIdentity: String]
    ) -> (owner: String, source: PortAttributionSource, chain: [pid_t])? {
        if let live = table.firstOwner(of: pid, resolve: { sessionPIDs[$0] }) {
            return (live.value, .liveChain, live.chain)
        }
        guard !remembered.isEmpty else { return nil }
        let recalled = table.firstOwner(of: pid) { walked in
            table.identity(of: walked).flatMap { remembered[$0] }
        }
        guard let recalled else { return nil }
        return (recalled.value, .ledger, recalled.chain)
    }

    /// A process that binds both an IPv4 and an IPv6 socket to one port is one row, not two.
    private struct PortKey: Hashable {
        let pid: pid_t
        let port: Int
    }
}

/// libproc was measured at ~10 ms per sweep against 1,059 processes versus ~152 ms for one
/// `lsof -i -P -n`, on the same socket set.
enum LibProc {
    static func allPIDs() -> [pid_t] {
        let probed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard probed > 0 else { return [] }
        // Processes can appear between the sizing call and the read, so ask for headroom.
        var buffer = [pid_t](repeating: 0, count: Int(probed) * 2 / MemoryLayout<pid_t>.size)
        let written = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_listpids(
                UInt32(PROC_ALL_PIDS),
                0,
                pointer.baseAddress,
                Int32(pointer.count * MemoryLayout<pid_t>.size)
            )
        }
        guard written > 0 else { return [] }
        return buffer.prefix(Int(written) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let written = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, size)
        }
        return written == size ? info : nil
    }

    /// `pbi_name` carries the accounting name and `pbi_comm` the truncated argv[0]; both are fixed
    /// C arrays, so they are read through their own storage rather than indexed.
    static func command(_ info: proc_bsdinfo) -> String {
        var name = info.pbi_name
        let accounting = withUnsafeBytes(of: &name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        if !accounting.isEmpty { return accounting }
        var comm = info.pbi_comm
        return withUnsafeBytes(of: &comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }

    /// `pbi_start_tvsec`/`pbi_start_tvusec` are the process's own start, not the boot-relative one,
    /// so the pair survives being written to disk and compared after a relaunch.
    static func startedAtMicros(_ info: proc_bsdinfo) -> Int64 {
        Int64(bitPattern: info.pbi_start_tvsec) * 1_000_000 + Int64(bitPattern: info.pbi_start_tvusec)
    }

    static func listeningTCPPorts(of pid: pid_t) -> [Int] {
        var probed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard probed > 0 else { return [] }
        probed += Int32(32 * MemoryLayout<proc_fdinfo>.size)
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(probed) / MemoryLayout<proc_fdinfo>.size)
        let written = fds.withUnsafeMutableBufferPointer { pointer in
            proc_pidinfo(
                pid,
                PROC_PIDLISTFDS,
                0,
                pointer.baseAddress,
                Int32(pointer.count * MemoryLayout<proc_fdinfo>.size)
            )
        }
        guard written > 0 else { return [] }

        var ports: [Int] = []
        for index in 0..<(Int(written) / MemoryLayout<proc_fdinfo>.size) {
            let fd = fds[index]
            guard fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) else { continue }
            var socketInfo = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            let got = withUnsafeMutablePointer(to: &socketInfo) {
                proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, $0, size)
            }
            guard got == size, socketInfo.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = socketInfo.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            // insi_lport is stored in network byte order.
            ports.append(Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))))
        }
        return ports
    }
}
