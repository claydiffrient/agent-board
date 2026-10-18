import Foundation

/// A project's teardown hook as Agent Board runs it: in the worktree, as its working directory,
/// just before the worktree is removed (SPEC §3.1 "Removing a worktree", §4).
public struct WorktreeTeardownCommand: Sendable, Equatable {
    /// Long enough for `bazel clean --expunge` to delete a 12 GB output base, short enough that a
    /// hook waiting forever (Bazel blocks on an output base another command holds) still ends.
    public static let defaultTimeoutSeconds = 600
    public static let timeoutRange = 1...86_400

    public var command: String
    public var timeoutSeconds: Int

    public init(command: String, timeoutSeconds: Int = defaultTimeoutSeconds) {
        self.command = command
        self.timeoutSeconds = Self.clampedTimeout(timeoutSeconds)
    }

    public static func clampedTimeout(_ seconds: Int) -> Int {
        min(max(seconds, timeoutRange.lowerBound), timeoutRange.upperBound)
    }
}

extension ProjectSettings {
    /// Nil when no command is set, including one cleared to blank in the settings sheet.
    public var worktreeTeardown: WorktreeTeardownCommand? {
        VerificationCommands.normalized(worktreeTeardownCommand).map {
            WorktreeTeardownCommand(command: $0, timeoutSeconds: worktreeTeardownTimeoutSeconds)
        }
    }
}
