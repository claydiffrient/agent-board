import Darwin
import Foundation

/// Runs a command as the leader of its own process group, with stdout and stderr on one pipe, and
/// stops the whole group once it outlives its deadline or the caller cancels it. The deadline is
/// measured on `CLOCK_UPTIME_RAW`, so time the machine spends asleep does not count against it.
public enum BoundedCommand {
    public struct Result: Sendable, Equatable {
        public enum Ending: Sendable, Equatable {
            case exited(Int32)
            case timedOut
            case canceled
        }

        public var ending: Ending
        /// The end of the combined output; at most `keptBytes` of it.
        public var output: String
    }

    static let keptBytes = 64 * 1024
    static let termGrace: UInt64 = 5_000_000_000
    /// After the leader exits, how long a straggler still holding the pipe open may keep it.
    static let drainGrace: UInt64 = 2_000_000_000

    public static func run(
        executable: String, arguments: [String], cwd: URL, environment: [String: String],
        timeout: TimeInterval, isCancelled: @Sendable () -> Bool = { false }
    ) throws -> Result {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw AgentRuntimeError("pipe failed: \(String(cString: strerror(errno)))") }
        let (readEnd, writeEnd) = (fds[0], fds[1])
        defer { close(readEnd) }

        let pid: pid_t
        do {
            pid = try spawn(executable, arguments, cwd: cwd, environment: environment, output: writeEnd)
        } catch {
            close(writeEnd)
            throw error
        }
        close(writeEnd)
        _ = fcntl(readEnd, F_SETFL, fcntl(readEnd, F_GETFL) | O_NONBLOCK)

        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let (sum, overflowed) = start.addingReportingOverflow(nanoseconds(timeout))
        let deadline = overflowed ? .max : sum
        var output = Data()
        var status: Int32?
        var ending: Result.Ending?
        var termSentAt: UInt64?
        var reapedAt: UInt64?
        var pipeOpen = true

        while pipeOpen || status == nil {
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            if status == nil, termSentAt == nil, now >= deadline || isCancelled() {
                ending = now >= deadline ? .timedOut : .canceled
                kill(-pid, SIGTERM)
                termSentAt = now
            }
            if status == nil, let sent = termSentAt, now >= sent + termGrace {
                kill(-pid, SIGKILL)
            }
            if let reaped = reapedAt, now >= reaped + drainGrace { break }

            if pipeOpen {
                var poller = pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)
                if poll(&poller, 1, 200) > 0 { pipeOpen = drain(readEnd, into: &output) }
            } else {
                usleep(50_000)
            }
            if status == nil {
                var raw: Int32 = 0
                if waitpid(pid, &raw, WNOHANG) == pid {
                    status = exitCode(raw)
                    reapedAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                    // The group outlives its leader while any member lives; nothing it left behind
                    // is wanted once the command is over.
                    kill(-pid, SIGKILL)
                }
            }
        }
        return Result(
            ending: ending ?? .exited(status ?? -1),
            output: String(decoding: output, as: UTF8.self)
        )
    }

    /// Saturates instead of trapping: negative or NaN is 0, and anything past `UInt64.max` is `.max`.
    static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        let nanoseconds = seconds * 1_000_000_000
        guard nanoseconds > 0 else { return 0 }
        return nanoseconds < Double(UInt64.max) ? UInt64(nanoseconds) : .max
    }

    /// False once the write end has closed.
    private static func drain(_ fd: Int32, into output: inout Data) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                output.append(buffer, count: count)
                if output.count > keptBytes { output.removeFirst(output.count - keptBytes) }
                continue
            }
            if count == 0 { return false }
            return errno == EAGAIN || errno == EINTR
        }
    }

    private static func exitCode(_ raw: Int32) -> Int32 {
        let signal = raw & 0x7f
        return signal == 0 ? (raw >> 8) & 0xff : 128 + signal
    }

    private static func spawn(
        _ executable: String, _ arguments: [String], cwd: URL, environment: [String: String], output: Int32
    ) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, output, 1)
        posix_spawn_file_actions_adddup2(&actions, output, 2)
        posix_spawn_file_actions_addchdir_np(&actions, cwd.path)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // posix_spawn copies the calling thread's signal mask, and a libdispatch worker thread
        // blocks SIGTERM: without resetting it the command could not be asked to stop.
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
        )
        posix_spawnattr_setpgroup(&attributes, 0)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        guard result == 0 else {
            throw AgentRuntimeError("could not start \(executable): \(String(cString: strerror(result)))")
        }
        return pid
    }
}
