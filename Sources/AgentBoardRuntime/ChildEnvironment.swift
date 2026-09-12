import Foundation

/// Environment for any claude process Agent Board launches. Variables that Claude Code sets on its own
/// children are stripped: inheriting them from a parent Claude session marks the new session as a child,
/// which turns transcript saving off and breaks metering and resume.
public enum ChildEnvironment {
    public static let strippedPrefixes = ["CLAUDE_CODE_", "CLAUDECODE", "CLAUDE_PID", "CLAUDE_ENV_FILE", "CLAUDE_EFFORT"]

    public static func sanitized(_ base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        base.filter { key, _ in !strippedPrefixes.contains { key.hasPrefix($0) } }
    }

    public static func forTerminal(_ base: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var env = sanitized(base)
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"]?.isEmpty ?? true { env["LANG"] = "en_US.UTF-8" }
        return env.map { "\($0.key)=\($0.value)" }
    }
}
