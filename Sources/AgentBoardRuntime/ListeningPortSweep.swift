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
    public let sessionId: String?

    public init(port: Int, pid: pid_t, command: String, sessionId: String?) {
        self.port = port
        self.pid = pid
        self.command = command
        self.sessionId = sessionId
    }
}

/// A pid -> (ppid, command) snapshot, built once per sweep so walking every chain stays linear.
public struct ProcessTable: Sendable {
    public struct Entry: Sendable, Equatable {
        public let ppid: pid_t
        public let command: String

        public init(ppid: pid_t, command: String) {
            self.ppid = ppid
            self.command = command
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
            entries[pid] = Entry(ppid: pid_t(bitPattern: info.pbi_ppid), command: LibProc.command(info))
        }
        return ProcessTable(entries: entries)
    }

    public func command(of pid: pid_t) -> String {
        entries[pid]?.command ?? ""
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
        // One pid list feeds both the parent map and the socket walk, so a socket on a process
        // whose `proc_pidinfo` lookup failed is still reported, just unattributed.
        let pids = LibProc.allPIDs()
        let table = ProcessTable.current(pids: pids)
        var ports: [ListeningPort] = []
        var seen: Set<PortKey> = []

        for pid in pids {
            for port in LibProc.listeningTCPPorts(of: pid) {
                guard port != boardServerPort else { continue }
                guard seen.insert(PortKey(pid: pid, port: port)).inserted else { continue }
                ports.append(
                    ListeningPort(
                        port: port,
                        pid: pid,
                        command: table.command(of: pid),
                        sessionId: table.owner(of: pid, in: sessionPIDs)
                    )
                )
            }
        }
        return ports.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
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
