import Foundation

/// A project's cleanup command as Agent Board runs it: in the project's own checkout, when free
/// disk space runs low or the human asks for a cleanup (SPEC §14.3).
public struct ProjectCleanupCommand: Sendable, Equatable {
    public static let defaultTimeoutSeconds = 1800
    public static let timeoutRange = WorktreeTeardownCommand.timeoutRange

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

/// What one run of a project's cleanup command did. A failure is a value here, never a thrown error.
public struct ProjectCleanupResult: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case exited(Int32)
        /// Its process group was sent `SIGTERM`, then `SIGKILL` five seconds later.
        case timedOut
        case couldNotStart(String)
    }

    public var command: String
    public var checkoutPath: String
    public var timeoutSeconds: Int
    public var outcome: Outcome
    /// The end of its combined stdout and stderr, trimmed; at most `outputKept` characters.
    public var outputTail: String

    public static let outputKept = 2_000

    public init(command: String, checkoutPath: String, timeoutSeconds: Int, outcome: Outcome, outputTail: String) {
        self.command = command
        self.checkoutPath = checkoutPath
        self.timeoutSeconds = timeoutSeconds
        self.outcome = outcome
        self.outputTail = outputTail
    }

    public var succeeded: Bool { outcome == .exited(0) }

    /// One paragraph for a notification body or a `decision` report.
    public var summary: String {
        let label = "The cleanup command `\(command)` in \(checkoutPath)"
        let tail = outputTail.isEmpty ? "" : "\nOutput:\n" + outputTail
        switch outcome {
        case .exited(0):
            return "\(label) finished.\(tail)"
        case .exited(let status):
            return "\(label) exited \(status).\(tail)"
        case .timedOut:
            return "\(label) did not finish within \(timeoutSeconds)s, so its process group was killed.\(tail)"
        case .couldNotStart(let reason):
            return "\(label) could not start: \(reason)"
        }
    }
}

extension ProjectSettings {
    /// Nil when no command is set, including one cleared to blank in the settings sheet.
    public var projectCleanup: ProjectCleanupCommand? {
        VerificationCommands.normalized(cleanupCommand).map {
            ProjectCleanupCommand(command: $0, timeoutSeconds: cleanupCommandTimeoutSeconds)
        }
    }
}
