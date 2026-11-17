import Foundation

/// Paths whose change can alter the rules a task's own agent reviewer loads from the worker's
/// checkout, or the CI that judges it. A completion touching one goes to a person (SPEC §5.1).
public enum ProtectedPaths {
    /// The paths among `paths` that are protected, in their original order. `extraGlobs` are the
    /// project's own patterns (`protectedPathGlobs`, SPEC §4): `*` and `?` stay within one path
    /// component, `**` spans any number of them.
    public static func matching(_ paths: [String], extraGlobs: [String] = []) -> [String] {
        let globs = extraGlobs.map { components(of: $0) }.filter { !$0.isEmpty }
        return paths.filter { path in
            let parts = components(of: path)
            return isBuiltIn(parts) || globs.contains { glob($0, matches: parts) }
        }
    }

    /// The review-rule names are matched case-insensitively, as macOS's default filesystem opens them;
    /// `.github/workflows` is read by GitHub, which is case-sensitive.
    private static func isBuiltIn(_ parts: [String]) -> Bool {
        guard let name = parts.last?.lowercased() else { return false }
        if name == "claude.md" || name == "claude.local.md" { return true }
        if parts.dropLast().contains(where: { $0.lowercased() == ".claude" }) { return true }
        if parts.count > 2, parts[0] == ".github", parts[1] == "workflows" { return true }
        return parts.count == 1 && name == ".mcp.json"
    }

    private static func components(of path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init).filter { $0 != "." }
    }

    private static func glob(_ pattern: [String], matches path: [String]) -> Bool {
        guard let head = pattern.first else { return path.isEmpty }
        let rest = Array(pattern.dropFirst())
        if head == "**" {
            return (0...path.count).contains { glob(rest, matches: Array(path.dropFirst($0))) }
        }
        guard let first = path.first, component(Array(head), matches: Array(first)) else { return false }
        return glob(rest, matches: Array(path.dropFirst()))
    }

    private static func component(_ pattern: [Character], matches name: [Character]) -> Bool {
        guard let head = pattern.first else { return name.isEmpty }
        let rest = Array(pattern.dropFirst())
        switch head {
        case "*":
            return (0...name.count).contains { component(rest, matches: Array(name.dropFirst($0))) }
        case "?":
            return !name.isEmpty && component(rest, matches: Array(name.dropFirst()))
        default:
            return name.first == head && component(rest, matches: Array(name.dropFirst()))
        }
    }
}

/// What a finished task changed, read from git by whoever calls `Board.complete`.
public enum CompletionChanges: Sendable, Equatable {
    case listed([String])
    /// git could not say, so no path can be ruled out.
    case unlisted(reason: String)
}
