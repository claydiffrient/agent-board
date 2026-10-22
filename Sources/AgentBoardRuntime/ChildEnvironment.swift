import Foundation

/// Environment for any claude process Agent Board launches. Variables that Claude Code sets on its own
/// children are stripped: inheriting them from a parent Claude session marks the new session as a child,
/// which turns transcript saving off and breaks metering and resume.
public enum ChildEnvironment {
    public static let strippedPrefixes = ["CLAUDE_CODE_", "CLAUDECODE", "CLAUDE_PID", "CLAUDE_ENV_FILE", "CLAUDE_EFFORT"]

    /// Colour forcing survives a pipe, so an inherited `FORCE_COLOR=3` puts ANSI escapes into the stdout
    /// Agent Board parses. `forTerminal` sets its own values back after calling `sanitized`.
    public static let strippedVariables: Set<String> = ["FORCE_COLOR", "COLORTERM", "CLICOLOR_FORCE"]

    public static func sanitized(
        _ base: [String: String] = ProcessInfo.processInfo.environment,
        path: String? = LoginShellPath.resolved
    ) -> [String: String] {
        var env = base.filter { key, _ in
            !strippedVariables.contains(key) && !strippedPrefixes.contains { key.hasPrefix($0) }
        }
        if let path { env["PATH"] = path }
        return env
    }

    /// A human's shell is not an agent session and gets none of a session's authority. Today a grant
    /// token and the board port reach a session only through the JSON config files named on its
    /// command line, so nothing here is live; the list is the standing guard that keeps it that way
    /// if that ever changes. `AGENTBOARD_SUPPORT_DIR` is on it because it points at the directory
    /// holding every live token in plaintext.
    public static let boardAuthorityVariables: Set<String> = [
        "AGENTBOARD_SUPPORT_DIR",
        "AGENTBOARD_TOKEN",
        "AGENTBOARD_GRANT",
        "AGENTBOARD_GRANT_TOKEN",
        "AGENTBOARD_PORT",
        "AGENT_BOARD_TOKEN",
        "AGENT_BOARD_PORT",
    ]

    /// The shell is a login shell and builds its own PATH, so the resolved one is not imposed on it.
    public static func forHumanShell(_ base: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        forTerminal(base.filter { key, _ in !boardAuthorityVariables.contains(key) }, path: nil)
    }

    /// Awaits the login-shell PATH without holding the caller's thread, so a terminal opened on the
    /// main thread before the lookup finishes does not freeze the UI.
    public static func forTerminal(
        _ base: [String: String] = ProcessInfo.processInfo.environment,
        lookup: LoginShellPathLookup = LoginShellPath.shared
    ) async -> [String] {
        forTerminal(base, path: await lookup.value)
    }

    public static func forTerminal(_ base: [String: String], path: String?) -> [String] {
        var env = sanitized(base, path: path)
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"]?.isEmpty ?? true { env["LANG"] = "en_US.UTF-8" }
        return env.map { "\($0.key)=\($0.value)" }
    }
}

/// The user's own shell, launched the way Terminal.app launches it.
public enum LoginShell {
    public static let fallback = "/bin/zsh"

    public static func path(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let shell = environment["SHELL"]?.trimmingCharacters(in: .whitespaces) ?? ""
        return shell.hasPrefix("/") ? shell : fallback
    }

    /// A leading `-` on argv[0] is what tells any POSIX shell it is a login shell, so the user's
    /// profile is sourced. SwiftTerm passes `execName` straight through as argv[0].
    public static func argv0(forPath path: String) -> String {
        "-" + URL(fileURLWithPath: path).lastPathComponent
    }
}

/// The PATH the user's interactive login shell builds. A Finder or Dock launch inherits launchd's
/// `/usr/bin:/bin:/usr/sbin:/sbin`, which leaves Homebrew, `~/.local/bin` and version managers off it (SPEC §2).
public enum LoginShellPath {
    static let marker = "__AGENTBOARD_PATH__="

    /// Run once per launch, by the first caller to need it.
    public static let shared = LoginShellPathLookup { query(shell: LoginShell.path()) }

    /// Blocks until the lookup finishes, up to `query`'s timeout, so it is for off-main callers only.
    public static var resolved: String? { shared.resolved }

    /// `-i` as well as `-l`, because `.zshrc` is where most PATH edits live. stdout goes to a file rather
    /// than a pipe so a background job the profile starts cannot hold the read open past the timeout.
    static func query(
        shell: String,
        base: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 5
    ) -> String? {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("agentboard-path-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: output.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: output) else { return nil }
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: output)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-i", "-l", "-c", "printf '\\n\(marker)%s\\n' \"$PATH\""]
        process.environment = ChildEnvironment.sanitized(base, path: nil)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return nil }
        guard waitForExit(process.processIdentifier, timeout: timeout) else {
            // An interactive zsh ignores SIGTERM.
            kill(process.processIdentifier, SIGKILL)
            return nil
        }

        guard let data = try? Data(contentsOf: output) else { return nil }
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// kqueue rather than `terminationHandler`, whose dispatch source never fires while a burst of
    /// callers holds every worker thread. Registering on a child that has already exited fails with ESRCH.
    private static func waitForExit(_ pid: pid_t, timeout: TimeInterval) -> Bool {
        let queue = kqueue()
        guard queue >= 0 else { return false }
        defer { close(queue) }
        var change = kevent(
            ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
            fflags: NOTE_EXIT, data: 0, udata: nil
        )
        let deadline = DispatchTime.now() + timeout
        while true {
            let now = DispatchTime.now()
            guard now < deadline else { return false }
            let remaining = deadline.uptimeNanoseconds - now.uptimeNanoseconds
            var wait = timespec(tv_sec: Int(remaining / 1_000_000_000), tv_nsec: Int(remaining % 1_000_000_000))
            var event = kevent()
            let count = kevent(queue, &change, 1, &event, 1, &wait)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return false }
            return event.flags & UInt16(EV_ERROR) == 0 || event.data == Int(ESRCH)
        }
    }

    static func parse(_ output: String) -> String? {
        output.split(whereSeparator: \.isNewline)
            .last { $0.hasPrefix(marker) }
            .map { String($0.dropFirst(marker.count)) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// One run of a login-shell PATH query, made by whichever caller asks first, on its own thread. Callers
/// that arrive while it runs wait for that run; blocking on work handed to a dispatch queue deadlocks once
/// as many callers wait as the machine has cores.
public final class LoginShellPathLookup: @unchecked Sendable {
    private enum State {
        case idle
        case running
        case finished(String?)
    }

    private let query: @Sendable () -> String?
    private let condition = NSCondition()
    private var state = State.idle

    public init(query: @escaping @Sendable () -> String?) {
        self.query = query
    }

    public var resolved: String? {
        condition.lock()
        defer { condition.unlock() }
        while true {
            switch state {
            case .finished(let path):
                return path
            case .running:
                condition.wait()
            case .idle:
                state = .running
                condition.unlock()
                let path = query()
                condition.lock()
                state = .finished(path)
                condition.broadcast()
                return path
            }
        }
    }

    public var value: String? {
        get async {
            await withCheckedContinuation { continuation in
                Thread.detachNewThread { continuation.resume(returning: self.resolved) }
            }
        }
    }
}
