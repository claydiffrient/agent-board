import AgentBoardCore
import Foundation

/// One `commit_my_work` per session at a time. Its commit hooks can outlast Claude Code's 60s wait
/// for an MCP answer, so a call waits a bounded time and a later call collects the outcome (SPEC §6).
/// An entry stays until a call has delivered its outcome.
actor CommitsInFlight {
    typealias Commit = _Concurrency.Task<ScopedCommitOutcome, Error>

    private var bySession: [String: Commit] = [:]

    /// The commit this session already has in flight or unreported, else a new one running `body`.
    func commit(
        sessionId: String, _ body: @escaping @Sendable () async throws -> ScopedCommitOutcome
    ) -> (commit: Commit, started: Bool) {
        if let existing = bySession[sessionId] { return (existing, false) }
        let commit = Commit { try await body() }
        bySession[sessionId] = commit
        return (commit, true)
    }

    func delivered(sessionId: String) {
        bySession[sessionId] = nil
    }

    /// Nil when `commit` is still running after `limit`.
    nonisolated static func outcome(
        of commit: Commit, within limit: Duration
    ) async -> Result<ScopedCommitOutcome, Error>? {
        await withCheckedContinuation { continuation in
            let first = FirstResume(continuation)
            let timer = _Concurrency.Task {
                try? await _Concurrency.Task.sleep(for: limit)
                first.resume(nil)
            }
            _Concurrency.Task {
                first.resume(await commit.result)
                timer.cancel()
            }
        }
    }
}

private final class FirstResume<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
