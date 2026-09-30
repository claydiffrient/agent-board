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

        public init(passed: [RefreshCheck] = [], failure: RefreshCheck? = nil, unverified: [RefreshCheck.Kind] = []) {
            self.passed = passed
            self.failure = failure
            self.unverified = unverified
        }
    }

    static let tailLines = 40
    static let tailCharacters = 4000

    /// Stops at the first failing command.
    public static func run(
        _ commands: VerificationCommands, in worktree: URL,
        environment: [String: String] = ChildEnvironment.sanitized()
    ) -> Outcome {
        let steps: [(RefreshCheck.Kind, String?)] = [(.build, commands.build), (.test, commands.test)]
        var outcome = Outcome(passed: [], failure: nil, unverified: steps.filter { $0.1 == nil }.map(\.0))
        for case let (kind, command?) in steps {
            let check = runOne(kind: kind, command: command, in: worktree, environment: environment)
            guard check.passed else {
                outcome.failure = check
                return outcome
            }
            outcome.passed.append(check)
        }
        return outcome
    }

    private static func runOne(
        kind: RefreshCheck.Kind, command: String, in worktree: URL, environment: [String: String]
    ) -> RefreshCheck {
        do {
            let result = try ProcessRunner.run(
                executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exec 2>&1\n" + command],
                cwd: worktree, environment: environment
            )
            let tail = result.status == 0 ? "" : Self.tail(result.stdout)
            return RefreshCheck(kind: kind, command: command, status: result.status, outputTail: tail)
        } catch {
            return RefreshCheck(kind: kind, command: command, status: -1, outputTail: String(describing: error))
        }
    }

    static func tail(_ output: String) -> String {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).suffix(tailLines)
        return String(lines.joined(separator: "\n").suffix(tailCharacters))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
