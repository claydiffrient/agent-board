import Foundation

/// Environment for any claude process Agent Board launches. Variables that Claude Code sets on its own
/// children are stripped: inheriting them from a parent Claude session marks the new session as a child,
/// which turns transcript saving off and breaks metering and resume.
public enum ChildEnvironment {
    public static let strippedPrefixes = ["CLAUDE_CODE_", "CLAUDECODE", "CLAUDE_PID", "CLAUDE_ENV_FILE", "CLAUDE_EFFORT"]

    /// Colour forcing survives a pipe, so an inherited `FORCE_COLOR=3` puts ANSI escapes into the stdout
    /// Agent Board parses. `forTerminal` sets its own values back after calling `sanitized`.
    public static let strippedVariables: Set<String> = ["FORCE_COLOR", "COLORTERM", "CLICOLOR_FORCE"]

    public static func sanitized(_ base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        base.filter { key, _ in
            !strippedVariables.contains(key) && !strippedPrefixes.contains { key.hasPrefix($0) }
        }
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

    public static func forHumanShell(_ base: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        forTerminal(base.filter { key, _ in !boardAuthorityVariables.contains(key) })
    }

    public static func forTerminal(_ base: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var env = sanitized(base)
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
