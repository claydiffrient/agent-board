import Foundation

public enum WorktreeRootError: LocalizedError, Equatable {
    case empty
    case containsSpace(String)

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "The worktree root cannot be empty."
        case .containsSpace(let path):
            return """
            The worktree root must not contain a space: "\(path)". \
            A space in a worktree path breaks any repository whose setup shells out without \
            quoting it — Bazel's workspace_status_command is one. Pick a path without spaces, \
            such as ~/.agentboard/worktrees.
            """
        }
    }
}

public enum WorktreeRootRule {
    public static func validate(_ path: String) throws {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorktreeRootError.empty
        }
        guard !path.contains(where: \.isWhitespace) else {
            throw WorktreeRootError.containsSpace(path)
        }
    }

    public static func isValid(_ path: String) -> Bool {
        (try? validate(path)) != nil
    }

    /// The stored root as a directory, with a leading `~` meaning `home` (SPEC §4). Foundation expands
    /// `~/` against the real home but resolves a bare `~` against the working directory.
    public static func url(_ path: String, home: URL) -> URL {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))) }
        return URL(fileURLWithPath: path)
    }
}
