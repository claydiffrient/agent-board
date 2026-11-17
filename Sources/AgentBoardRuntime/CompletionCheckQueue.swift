import AgentBoardCore
import Foundation

/// Runs completion checks one at a time, in the order asked, across every project (SPEC §5.1): a
/// check is a build or tests, and several at once is what drove this machine's load past 20.
public final class CompletionCheckQueue: Sendable {
    private let queue = DispatchQueue(label: "agentboard.completion-check")

    public init() {}

    public func run(
        _ commands: [String], timeoutSeconds: Int, in worktree: URL,
        environment: [String: String] = ChildEnvironment.sanitized(),
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async -> CompletionCheck {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: RefreshVerifier.completionCheck(
                    commands, timeoutSeconds: timeoutSeconds, in: worktree,
                    environment: environment, isCancelled: isCancelled
                ))
            }
        }
    }
}
