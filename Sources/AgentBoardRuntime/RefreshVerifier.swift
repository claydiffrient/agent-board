import AgentBoardCore
import Foundation

/// Runs a project's configured build, then test, command in a checkout of a refresh's merge result
/// (SPEC §5.2). A command the project does not configure is not guessed at: it is left for the
/// caller to report as unverified.
public enum RefreshVerifier {
    public struct Outcome: Sendable, Equatable {
        public var passed: [RefreshCheck]
        public var failure: RefreshCheck?
        public var unverified: [RefreshCheck.Kind]
        /// The command that was running when the caller canceled the run; it was stopped, not failed.
        public var canceled: String?

        public init(
            passed: [RefreshCheck] = [], failure: RefreshCheck? = nil, unverified: [RefreshCheck.Kind] = [],
            canceled: String? = nil
        ) {
            self.passed = passed
            self.failure = failure
            self.unverified = unverified
            self.canceled = canceled
        }
    }

    static let tailLines = 40
    static let tailCharacters = 4000

    /// Stops at the first failing command. Each command gets `commands.timeoutSeconds` of awake time.
    public static func run(
        _ commands: VerificationCommands, in worktree: URL,
        environment: [String: String] = ChildEnvironment.sanitized(),
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) -> Outcome {
        let steps: [(RefreshCheck.Kind, String?)] = [(.build, commands.build), (.test, commands.test)]
        var outcome = Outcome(passed: [], failure: nil, unverified: steps.filter { $0.1 == nil }.map(\.0))
        for case let (kind, command?) in steps {
            let result: BoundedCommand.Result
            do {
                result = try BoundedCommand.run(
                    executable: "/bin/sh", arguments: ["-c", command], cwd: worktree, environment: environment,
                    timeout: TimeInterval(commands.timeoutSeconds), isCancelled: isCancelled
                )
            } catch {
                outcome.failure = RefreshCheck(kind: kind, command: command, status: -1, outputTail: String(describing: error))
                return outcome
            }
            let check: RefreshCheck
            switch result.ending {
            case .canceled:
                outcome.canceled = command
                return outcome
            case .timedOut:
                check = RefreshCheck(
                    kind: kind, command: command, status: -1, outputTail: tail(result.output),
                    timedOutAfter: commands.timeoutSeconds
                )
            case .exited(let status):
                check = RefreshCheck(kind: kind, command: command, status: status, outputTail: status == 0 ? "" : tail(result.output))
            }
            guard check.passed else {
                outcome.failure = check
                return outcome
            }
            outcome.passed.append(check)
        }
        return outcome
    }

    static func tail(_ output: String) -> String {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).suffix(tailLines)
        return String(lines.joined(separator: "\n").suffix(tailCharacters))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
