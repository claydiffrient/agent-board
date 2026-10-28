import Foundation

public struct CommandResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public struct AgentRuntimeError: Error, CustomStringConvertible, Sendable {
    public var description: String

    public init(_ description: String) {
        self.description = description
    }
}

enum ProcessRunner {
    /// How long stderr may stay open once stdout has closed, as when a grandchild still holds it.
    static let pipeDrainTimeout: TimeInterval = 60

    static func run(
        executable: URL,
        arguments: [String],
        cwd: URL? = nil,
        stdin: Data? = nil,
        environment: [String: String]? = nil
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.environment = environment ?? ChildEnvironment.sanitized()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdinPipe: Pipe?
        if stdin != nil {
            stdinPipe = Pipe()
            process.standardInput = stdinPipe
        } else {
            stdinPipe = nil
            process.standardInput = FileHandle.nullDevice
        }

        let descriptors = DescriptorLog.descriptors("stdout", stdoutPipe) + DescriptorLog.descriptors("stderr", stderrPipe)
            + (stdinPipe.map { DescriptorLog.descriptors("stdin", $0) } ?? [])
        do {
            try process.run()
        } catch {
            DescriptorLog.launchFailed(
                executable.path, arguments: arguments, cwd: cwd, descriptors: descriptors, error: error
            )
            throw error
        }

        guard let output = exchange(stdout: stdoutPipe, stderr: stderrPipe, stdin: stdinPipe.map { ($0, stdin ?? Data()) })
        else {
            process.terminate()
            throw AgentRuntimeError(
                "\(executable.lastPathComponent) \(arguments.joined(separator: " ")) did not finish "
                    + "within \(Int(pipeDrainTimeout))s"
            )
        }
        process.waitUntilExit()

        return CommandResult(
            status: process.terminationStatus,
            stdout: String(decoding: output.stdout, as: UTF8.self),
            stderr: String(decoding: output.stderr, as: UTF8.self)
        )
    }

    /// Feeds stdin and drains both pipes on the calling thread; nil past `deadline`, or, without an `exitWatch`,
    /// when stderr outlives stdout by `pipeDrainTimeout`. Once `exitWatch` turns readable it takes only
    /// what is already buffered, and past `deadline` returns what it has, so a grandchild holding or
    /// flooding a pipe cannot stall it. Handing a pipe to a dispatch queue instead deadlocks once as
    /// many callers block here as the machine has cores: libdispatch then schedules none of their readers.
    static func exchange(
        stdout: Pipe, stderr: Pipe, stdin: (Pipe, Data)?, exitWatch: ExitWatch? = nil, deadline: DispatchTime? = nil
    ) -> (stdout: Data, stderr: Data)? {
        let writer = stdin?.0.fileHandleForWriting
        let input = stdin?.1 ?? Data()
        var written = 0
        if let writer {
            _ = fcntl(writer.fileDescriptor, F_SETFL, fcntl(writer.fileDescriptor, F_GETFL) | O_NONBLOCK)
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
            if input.isEmpty { try? writer.close() }
        }
        var fds = [
            pollfd(fd: stdout.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0),
            pollfd(fd: stderr.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0),
            pollfd(fd: writer.flatMap { input.isEmpty ? nil : $0.fileDescriptor } ?? -1, events: Int16(POLLOUT), revents: 0),
            pollfd(fd: exitWatch?.descriptor ?? -1, events: Int16(POLLIN), revents: 0),
        ]
        var collected = [Data(), Data()]
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var stderrDeadline: DispatchTime?
        var exited = false

        while fds[0].fd >= 0 || fds[1].fd >= 0 {
            var wait: Int32 = -1
            if let limit = [stderrDeadline, deadline].compactMap({ $0 }).min() {
                let now = DispatchTime.now()
                guard now < limit else {
                    if exited { break }
                    return nil
                }
                wait = Int32(min((limit.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000_000 + 1, 1000))
            }
            if exited { wait = 0 }
            let ready = poll(&fds, nfds_t(fds.count), wait)
            if ready == 0, exited { break }
            guard ready > 0 else { continue }
            if fds[3].fd >= 0, fds[3].revents != 0 {
                exited = true
                fds[3].fd = -1
            }

            for index in 0..<2 where fds[index].fd >= 0 && fds[index].revents != 0 {
                let count = read(fds[index].fd, &buffer, buffer.count)
                if count > 0 {
                    collected[index].append(buffer, count: count)
                } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                    fds[index].fd = -1
                    if index == 0, fds[1].fd >= 0, exitWatch == nil { stderrDeadline = .now() + pipeDrainTimeout }
                }
            }
            if let writer, fds[2].fd >= 0, fds[2].revents != 0 {
                let count = input.withUnsafeBytes { bytes in
                    Darwin.write(fds[2].fd, bytes.baseAddress! + written, bytes.count - written)
                }
                if count > 0 { written += count }
                if written == input.count || (count < 0 && errno != EINTR && errno != EAGAIN) {
                    fds[2].fd = -1
                    try? writer.close()
                }
            }
        }
        if fds[2].fd >= 0 { try? writer?.close() }
        return (collected[0], collected[1])
    }

    /// Bounded from launch: past `timeout` a child still running is terminated and this throws. Reading stops at the
    /// child's exit, so a grandchild that keeps a pipe open (git's ssh) cannot stall the caller.
    static func run(
        executable: URL,
        arguments: [String],
        cwd: URL? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval
    ) throws -> CommandResult {
        let deadline = DispatchTime.now() + timeout
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.environment = environment ?? ChildEnvironment.sanitized()
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // Foundation frees a Process's pipes only once `waitUntilExit` or a run loop sees the exit, and
        // `ExitWatch` is neither: without this every call leaked both read ends until the app ran out of fds.
        defer {
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
        }

        let descriptors = DescriptorLog.descriptors("stdout", stdoutPipe) + DescriptorLog.descriptors("stderr", stderrPipe)
        do {
            try process.run()
        } catch {
            DescriptorLog.launchFailed(
                executable.path, arguments: arguments, cwd: cwd, descriptors: descriptors, error: error
            )
            throw error
        }
        let exitWatch: ExitWatch
        do {
            exitWatch = try ExitWatch(process)
        } catch {
            process.terminate()
            throw error
        }
        guard let output = exchange(stdout: stdoutPipe, stderr: stderrPipe, stdin: nil, exitWatch: exitWatch, deadline: deadline),
              let status = exitWatch.status(by: deadline)
        else {
            process.terminate()
            if exitWatch.status(by: .now() + 1) == nil { kill(process.processIdentifier, SIGKILL) }
            throw AgentRuntimeError(
                "\(executable.lastPathComponent) \(arguments.joined(separator: " ")) did not finish within \(Int(timeout))s"
            )
        }
        return CommandResult(
            status: status,
            stdout: String(decoding: output.stdout, as: UTF8.self),
            stderr: String(decoding: output.stderr, as: UTF8.self)
        )
    }

    static func runChecked(
        executable: URL,
        arguments: [String],
        cwd: URL? = nil,
        stdin: Data? = nil,
        timeout: TimeInterval? = nil,
        label: String
    ) throws -> CommandResult {
        let result = if let timeout {
            try run(executable: executable, arguments: arguments, cwd: cwd, timeout: timeout)
        } else {
            try run(executable: executable, arguments: arguments, cwd: cwd, stdin: stdin)
        }
        guard result.status == 0 else {
            throw AgentRuntimeError(
                "\(label) \(arguments.joined(separator: " ")) exited \(result.status)\nstdout:\n\(result.stdout)\nstderr:\n\(result.stderr)"
            )
        }
        return result
    }
}

/// A kqueue that turns readable once the child exits. It never reaps the child, which stays Foundation's
/// to collect, and it needs no dispatch thread, which a burst of callers would starve.
final class ExitWatch {
    let descriptor: Int32
    private let process: Process

    init(_ process: Process) throws {
        descriptor = kqueue()
        guard descriptor >= 0 else {
            let code = errno
            throw AgentRuntimeError("kqueue() failed with errno \(code) (\(String(cString: strerror(code))))")
        }
        self.process = process
        var processExit = kevent(
            ident: UInt(process.processIdentifier), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
            fflags: UInt32(NOTE_EXIT) | UInt32(NOTE_EXITSTATUS), data: 0, udata: nil
        )
        if kevent(descriptor, &processExit, 1, nil, 0, nil) != 0 {
            // ESRCH: the child has already exited, zombie or reaped.
            var exited = kevent(
                ident: 0, filter: Int16(EVFILT_USER), flags: UInt16(EV_ADD | EV_ONESHOT),
                fflags: UInt32(NOTE_TRIGGER), data: 0, udata: nil
            )
            _ = kevent(descriptor, &exited, 1, nil, 0, nil)
        }
    }

    deinit { DescriptorLog.closeChecked(descriptor, site: "ExitWatch.deinit") }

    /// What `Process.terminationStatus` reports, or nil while the child is still running at `deadline`.
    func status(by deadline: DispatchTime) -> Int32? {
        let remaining = deadline.uptimeNanoseconds.subtractingReportingOverflow(DispatchTime.now().uptimeNanoseconds)
        let nanoseconds = remaining.overflow ? 0 : remaining.partialValue
        var wait = timespec(tv_sec: Int(nanoseconds / 1_000_000_000), tv_nsec: Int(nanoseconds % 1_000_000_000))
        var event = kevent()
        guard kevent(descriptor, nil, 0, &event, 1, &wait) == 1 else { return nil }
        if event.filter == Int16(EVFILT_PROC) {
            let status = Int32(truncatingIfNeeded: event.data)
            return status & 0x7f == 0 ? (status >> 8) & 0xff : status & 0x7f
        }
        var info = siginfo_t()
        if waitid(P_PID, id_t(process.processIdentifier), &info, WEXITED | WNOWAIT) == 0 { return info.si_status }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
