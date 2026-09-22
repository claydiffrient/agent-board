import Darwin
import Foundation

/// One TCP socket in `LISTEN`, with the Agent Board session it was traced back to.
///
/// `sessionId` is nil for a socket whose parent chain reaches pid 1 or a process the board never
/// launched, with no ledger entry to name it. The sweep still reports it; whether a nil owner is
/// worth drawing is the caller's decision.
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

/// One process holding a listening TCP socket. A process bound on both IPv4 and IPv6 holds the port
/// once, not twice.
public struct PortHolder: Hashable, Sendable {
    public let pid: pid_t
    public let port: Int

    public init(pid: pid_t, port: Int) {
        self.pid = pid
        self.port = port
    }
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
        let holders = pids.flatMap { pid in
            LibProc.listeningTCPPorts(of: pid).map { PortHolder(pid: pid, port: $0) }
        }
        return sweepResult(
            holders: holders,
            table: ProcessTable.current(pids: pids),
            sessionPIDs: sessionPIDs,
            remembered: remembered,
            boardServerPort: boardServerPort
        )
    }

    /// The sweep over an already-read snapshot: every `(pid, port)` pair holding a listening
    /// socket, and the process table those pids were read from.
    ///
    /// **One port is one row.** A descriptor inherited across `fork` is held by the whole tree
    /// below the process that bound it, so one socket shows up under several pids. The row goes to
    /// the holder that started first, which is the binder: no process can inherit a descriptor
    /// before the process holding it exists. Every holder's chain is still recorded, so a child
    /// that outlives the binder stays nameable from the ledger.
    public static func sweepResult(
        holders: [PortHolder],
        table: ProcessTable,
        sessionPIDs: [pid_t: String],
        remembered: [PIDIdentity: String],
        boardServerPort: Int?
    ) -> PortSweepResult {
        var attributions: [PIDIdentity: String] = [:]
        var owners: [Int: (holder: PortHolder, attributed: Attribution?)] = [:]

        for holder in Set(holders) where holder.port != boardServerPort {
            let attributed = attribute(pid: holder.pid, table: table, sessionPIDs: sessionPIDs, remembered: remembered)
            if let attributed {
                for walked in attributed.chain {
                    guard let identity = table.identity(of: walked) else { continue }
                    attributions[identity] = attributed.owner
                }
            }
            if let current = owners[holder.port], !startedFirst(holder.pid, before: current.holder.pid, in: table) {
                continue
            }
            owners[holder.port] = (holder, attributed)
        }

        let ports = owners.values.map { owner in
            ListeningPort(
                port: owner.holder.port,
                pid: owner.holder.pid,
                command: table.command(of: owner.holder.pid),
                sessionId: owner.attributed?.owner,
                source: owner.attributed?.source
            )
        }
        return PortSweepResult(
            ports: ports.sorted { $0.port < $1.port },
            attributions: attributions,
            liveIdentities: table.liveIdentities
        )
    }

    /// A pid the table could not read sorts after every pid it could, then the lower pid wins, so
    /// the choice never depends on the order `proc_listpids` returned them in.
    private static func startedFirst(_ pid: pid_t, before other: pid_t, in table: ProcessTable) -> Bool {
        let started = table.entries[pid]?.startedAtMicros ?? .max
        let otherStarted = table.entries[other]?.startedAtMicros ?? .max
        return (started, pid) < (otherStarted, other)
    }

    private typealias Attribution = (owner: String, source: PortAttributionSource, chain: [pid_t])

    private static func attribute(
        pid: pid_t,
        table: ProcessTable,
        sessionPIDs: [pid_t: String],
        remembered: [PIDIdentity: String]
    ) -> Attribution? {
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
