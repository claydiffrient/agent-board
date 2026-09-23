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

    public static func forTerminal(
        _ base: [String: String] = ProcessInfo.processInfo.environment,
        path: String? = LoginShellPath.resolved
    ) -> [String] {
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

    /// Resolved once per launch; the first reader blocks for the shell's startup (under a second here).
    public static let resolved: String? = query(shell: LoginShell.path())

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

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            // An interactive zsh ignores SIGTERM.
            kill(process.processIdentifier, SIGKILL)
            return nil
        }

        guard let data = try? Data(contentsOf: output) else { return nil }
        return parse(String(decoding: data, as: UTF8.self))
    }

    static func parse(_ output: String) -> String? {
        output.split(whereSeparator: \.isNewline)
            .last { $0.hasPrefix(marker) }
            .map { String($0.dropFirst(marker.count)) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }
}
