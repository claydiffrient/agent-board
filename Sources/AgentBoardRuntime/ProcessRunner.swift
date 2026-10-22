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

        try process.run()

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

    /// Feeds stdin and drains both pipes on the calling thread; nil when stderr outlives stdout by
    /// `pipeDrainTimeout`. Handing a pipe to a dispatch queue instead deadlocks once as many callers
    /// block here as the machine has cores: libdispatch then schedules none of their readers.
    private static func exchange(stdout: Pipe, stderr: Pipe, stdin: (Pipe, Data)?) -> (stdout: Data, stderr: Data)? {
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
        ]
        var collected = [Data(), Data()]
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var stderrDeadline: DispatchTime?

        while fds[0].fd >= 0 || fds[1].fd >= 0 {
            var wait: Int32 = -1
            if let stderrDeadline {
                let now = DispatchTime.now()
                guard now < stderrDeadline else { return nil }
                wait = Int32(min((stderrDeadline.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000_000 + 1, 1000))
            }
            guard poll(&fds, nfds_t(fds.count), wait) > 0 else { continue }

            for index in 0..<2 where fds[index].fd >= 0 && fds[index].revents != 0 {
                let count = read(fds[index].fd, &buffer, buffer.count)
                if count > 0 {
                    collected[index].append(buffer, count: count)
                } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                    fds[index].fd = -1
                    if index == 0, fds[1].fd >= 0 { stderrDeadline = .now() + pipeDrainTimeout }
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

    /// Bounded from launch: past `timeout` the child is terminated and this throws. Each pipe drains
    /// on its own thread, so a grandchild that keeps one open (git's ssh) cannot stall the caller.
    static func run(
        executable: URL,
        arguments: [String],
        cwd: URL? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval
    ) throws -> CommandResult {
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
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        try process.run()
        let stdout = PipeCapture(stdoutPipe)
        let stderr = PipeCapture(stderrPipe)
        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if exited.wait(timeout: .now() + 1) != .success { kill(process.processIdentifier, SIGKILL) }
            throw AgentRuntimeError(
                "\(executable.lastPathComponent) \(arguments.joined(separator: " ")) did not finish within \(Int(timeout))s"
            )
        }
        return CommandResult(
            status: process.terminationStatus, stdout: stdout.collected(), stderr: stderr.collected()
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

private final class PipeCapture: @unchecked Sendable {
    private var data = Data()
    private let done = DispatchSemaphore(value: 0)

    init(_ pipe: Pipe) {
        DispatchQueue.global().async {
            self.data = pipe.fileHandleForReading.readDataToEndOfFile()
            self.done.signal()
        }
    }

    /// Empty when the pipe is still held open after the child exited.
    func collected(within seconds: TimeInterval = 2) -> String {
        guard done.wait(timeout: .now() + seconds) == .success else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
