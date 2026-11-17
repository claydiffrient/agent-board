import Foundation

/// The board's own check of a finished task: the project's "Check at completion" commands, run in the
/// task's worktree after `report_complete` and before review is routed (SPEC §5.1). No steps means
/// the project configures none, so the work is not verified by the board.
public struct CompletionCheck: Codable, Sendable, Equatable {
    public enum StepResult: String, Codable, Sendable {
        case passed
        case failed
        case timedOut = "timed_out"
        /// An earlier command failed, so this one was not started.
        case notRun = "not_run"
    }

    public struct Step: Codable, Sendable, Equatable {
        public var command: String
        public var result: StepResult
        /// Nil when the command never exited on its own: it timed out, was not run, or could not start.
        public var exitStatus: Int32?
        public var seconds: Double
        /// Kept only for a failure.
        public var outputTail: String

        public init(command: String, result: StepResult, exitStatus: Int32? = nil, seconds: Double = 0, outputTail: String = "") {
            self.command = command
            self.result = result
            self.exitStatus = exitStatus
            self.seconds = seconds
            self.outputTail = outputTail
        }

        public var line: String {
            let took = CompletionCheck.duration(seconds)
            switch result {
            case .passed: return "`\(command)` passed in \(took)."
            case .failed:
                return exitStatus.map { "`\(command)` failed: exited \($0) after \(took)." }
                    ?? "`\(command)` failed: it could not be run."
            case .timedOut: return "`\(command)` failed: timed out after \(took) and was stopped."
            case .notRun: return "`\(command)` was not run, because an earlier command failed."
            }
        }
    }

    public var steps: [Step]
    public var startedAt: Int64
    /// Nil while the check is queued or running.
    public var finishedAt: Int64?
    /// Set when Agent Board stopped while a command ran; that command was stopped, not failed.
    public var interrupted: Bool

    public init(steps: [Step], startedAt: Int64, finishedAt: Int64?, interrupted: Bool = false) {
        self.steps = steps
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.interrupted = interrupted
    }

    public static func notVerified(at: Int64 = .nowMillis) -> CompletionCheck {
        CompletionCheck(steps: [], startedAt: at, finishedAt: at)
    }

    public static func running(_ commands: [String], at: Int64 = .nowMillis) -> CompletionCheck {
        CompletionCheck(steps: commands.map { Step(command: $0, result: .notRun) }, startedAt: at, finishedAt: nil)
    }

    /// The first command failed without running, with `reason` as its output; the rest were not run.
    public static func couldNotRun(_ commands: [String], reason: String, at: Int64 = .nowMillis) -> CompletionCheck {
        let steps = commands.enumerated().map { index, command in
            index == 0
                ? Step(command: command, result: .failed, outputTail: reason)
                : Step(command: command, result: .notRun)
        }
        return CompletionCheck(steps: steps, startedAt: at, finishedAt: at)
    }

    public var isRunning: Bool { finishedAt == nil }
    public var isNotVerified: Bool { steps.isEmpty && !isRunning }
    public var passed: Bool { !isRunning && !interrupted && !steps.isEmpty && steps.allSatisfy { $0.result == .passed } }
    public var failure: Step? { steps.first { $0.result == .failed || $0.result == .timedOut } }

    public static let notVerifiedText = "Not verified by the board: this project configures no Check at completion commands."

    public var headline: String {
        if isRunning { return "Agent Board's completion check is running." }
        if steps.isEmpty { return Self.notVerifiedText }
        if interrupted { return "Agent Board's completion check was interrupted: Agent Board stopped while it ran." }
        return failure == nil ? "Agent Board's completion check passed." : "Agent Board's completion check failed."
    }

    /// The headline, a line per command, and the failing command's output tail.
    public var report: String {
        var lines = [headline]
        if isRunning {
            lines += steps.map { "- `\($0.command)`" }
            return lines.joined(separator: "\n")
        }
        lines += steps.map { "- " + $0.line }
        if let failure, !failure.outputTail.isEmpty {
            lines += ["", "End of `\(failure.command)`'s output:", failure.outputTail]
        }
        return lines.joined(separator: "\n")
    }

    static func duration(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        if whole < 60 { return "\(whole)s" }
        return whole % 60 == 0 ? "\(whole / 60)m" : "\(whole / 60)m \(whole % 60)s"
    }
}
