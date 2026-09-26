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
    /// However long a subprocess legitimately runs, its stderr pipe must drain in this long once
    /// stdout has. Past it the drain never scheduling is worth failing loudly for, rather than the
    /// semaphore below waiting forever with no signal to say why: measured cause of a `swift test`
    /// run that outlived its own watchdog by hours (2026-09-26), once enough leaked background
    /// `Task`s elsewhere had exhausted libdispatch's worker-thread pool.
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

        if let stdinPipe, let stdin {
            let writer = stdinPipe.fileHandleForWriting
            DispatchQueue.global().async {
                try? writer.write(contentsOf: stdin)
                try? writer.close()
            }
        }

        let stderrBox = DataBox()
        let stderrDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            stderrBox.data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            stderrDone.signal()
        }
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        guard stderrDone.wait(timeout: .now() + pipeDrainTimeout) == .success else {
            process.terminate()
            throw AgentRuntimeError(
                "\(executable.lastPathComponent) \(arguments.joined(separator: " ")) did not finish "
                    + "within \(Int(pipeDrainTimeout))s"
            )
        }
        process.waitUntilExit()

        return CommandResult(
            status: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrBox.data, as: UTF8.self)
        )
    }

    static func runChecked(
        executable: URL,
        arguments: [String],
        cwd: URL? = nil,
        stdin: Data? = nil,
        label: String
    ) throws -> CommandResult {
        let result = try run(executable: executable, arguments: arguments, cwd: cwd, stdin: stdin)
        guard result.status == 0 else {
            throw AgentRuntimeError(
                "\(label) \(arguments.joined(separator: " ")) exited \(result.status)\nstdout:\n\(result.stdout)\nstderr:\n\(result.stderr)"
            )
        }
        return result
    }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}
