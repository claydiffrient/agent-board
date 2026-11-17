import AgentBoardCore
import Foundation

/// Runs the build, then test, commands a project's integration verification lets a refresh run, in a
/// checkout of its merge result (SPEC §5.2). A command the project does not configure is not guessed
/// at: it is left for the caller to report as unverified.
public enum RefreshVerifier {
    public struct Outcome: Sendable, Equatable {
        public var passed: [RefreshCheck]
        public var failure: RefreshCheck?
        public var unverified: [RefreshCheck.Kind]
        public var testsLeftToCI: Bool
        /// The command that was running when the caller canceled the run; it was stopped, not failed.
        public var canceled: String?

        public init(
            passed: [RefreshCheck] = [], failure: RefreshCheck? = nil, unverified: [RefreshCheck.Kind] = [],
            testsLeftToCI: Bool = false, canceled: String? = nil
        ) {
            self.passed = passed
            self.failure = failure
            self.unverified = unverified
            self.testsLeftToCI = testsLeftToCI
            self.canceled = canceled
        }

        /// Before anything has run: each of `commands.refreshSteps` with no command is unverified.
        public init(nothingRunFor commands: VerificationCommands) {
            let steps = commands.refreshSteps
            self.init(
                unverified: steps.filter { $0.command == nil }.map(\.kind),
                testsLeftToCI: !steps.contains { $0.kind == .test }
            )
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
        var outcome = Outcome(nothingRunFor: commands)
        for case let (kind, command?) in commands.refreshSteps {
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

    /// A finished task's "Check at completion" commands (SPEC §5.1), stopping at the first failure. Each
    /// gets `timeoutSeconds` of awake time; the commands after a failure are recorded as not run.
    public static func completionCheck(
        _ commands: [String], timeoutSeconds: Int, in worktree: URL,
        environment: [String: String] = ChildEnvironment.sanitized(),
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) -> CompletionCheck {
        var check = CompletionCheck(steps: [], startedAt: .nowMillis, finishedAt: nil)
        let clock = ContinuousClock()
        for command in commands {
            guard check.failure == nil, !check.interrupted else {
                check.steps.append(CompletionCheck.Step(command: command, result: .notRun))
                continue
            }
            let started = clock.now
            let ran = Swift.Result {
                try BoundedCommand.run(
                    executable: "/bin/sh", arguments: ["-c", command], cwd: worktree, environment: environment,
                    timeout: TimeInterval(timeoutSeconds), isCancelled: isCancelled
                )
            }
            let elapsed = clock.now - started
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            switch ran {
            case .failure(let error):
                check.steps.append(CompletionCheck.Step(
                    command: command, result: .failed, seconds: seconds, outputTail: String(describing: error)
                ))
            case .success(let result):
                switch result.ending {
                case .canceled:
                    check.interrupted = true
                    check.steps.append(CompletionCheck.Step(command: command, result: .notRun, seconds: seconds))
                case .timedOut:
                    check.steps.append(CompletionCheck.Step(
                        command: command, result: .timedOut, seconds: seconds, outputTail: tail(result.output)
                    ))
                case .exited(let status):
                    check.steps.append(CompletionCheck.Step(
                        command: command, result: status == 0 ? .passed : .failed, exitStatus: status,
                        seconds: seconds, outputTail: status == 0 ? "" : tail(result.output)
                    ))
                }
            }
        }
        check.finishedAt = .nowMillis
        return check
    }

    static func tail(_ output: String) -> String {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).suffix(tailLines)
        return String(lines.joined(separator: "\n").suffix(tailCharacters))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
