import Darwin

/// NIO sets `SOCK_CLOEXEC` only on Linux, and SwiftTerm starts the orchestrator and shell consoles with
/// `forkpty` + `execve`, so without this every PTY child inherits the board's listening socket (SPEC §3.2).
enum ListenerCloseOnExec {
    static func mark(port: Int) {
        for fd in listeningDescriptors(port: port) {
            let flags = fcntl(fd, F_GETFD)
            if flags >= 0 { _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC) }
        }
    }

    private static func listeningDescriptors(port: Int) -> [Int32] {
        let pid = getpid()
        var probed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard probed > 0 else { return [] }
        probed += Int32(32 * MemoryLayout<proc_fdinfo>.size)
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(probed) / MemoryLayout<proc_fdinfo>.size)
        let written = fds.withUnsafeMutableBufferPointer { pointer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, pointer.baseAddress, Int32(pointer.count * MemoryLayout<proc_fdinfo>.size))
        }
        guard written > 0 else { return [] }

        return fds.prefix(Int(written) / MemoryLayout<proc_fdinfo>.size).compactMap { fd in
            guard fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) else { return nil }
            var socketInfo = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            let got = withUnsafeMutablePointer(to: &socketInfo) {
                proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, $0, size)
            }
            guard got == size, socketInfo.psi.soi_kind == SOCKINFO_TCP else { return nil }
            let tcp = socketInfo.psi.soi_proto.pri_tcp
            let localPort = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
            return tcp.tcpsi_state == TSI_S_LISTEN && localPort == port ? fd.proc_fd : nil
        }
    }
}
