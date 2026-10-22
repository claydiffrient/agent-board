import AgentBoardCore
import Foundation

/// One `commit_my_work` per session at a time. Its commit hooks can outlast Claude Code's 60s wait
/// for an MCP answer, so a call waits a bounded time and a later call collects the outcome (SPEC §6).
/// An entry stays until a call has delivered its outcome.
public actor CommitsInFlight {
    typealias Commit = _Concurrency.Task<ScopedCommitOutcome, Error>

    private struct Entry {
        let id: UUID
        let taskId: String
        let commit: Commit
        var running = true
    }

    private var bySession: [String: Entry] = [:]

    public init() {}

    /// The commit this session already has in flight or unreported, else a new one running `body`.
    func commit(
        sessionId: String, taskId: String, _ body: @escaping @Sendable () async throws -> ScopedCommitOutcome
    ) -> (commit: Commit, id: UUID, started: Bool) {
        if let existing = bySession[sessionId] { return (existing.commit, existing.id, false) }
        let id = UUID()
        let commit = Commit {
            let result: Result<ScopedCommitOutcome, Error>
            do { result = .success(try await body()) } catch { result = .failure(error) }
            await self.finished(sessionId: sessionId, id: id)
            return try result.get()
        }
        bySession[sessionId] = Entry(id: id, taskId: taskId, commit: commit)
        return (commit, id, true)
    }

    /// Removes the entry only while it is still commit `id`, so a late delivery never clears a newer commit.
    func delivered(sessionId: String, id: UUID) {
        if bySession[sessionId]?.id == id { bySession[sessionId] = nil }
    }

    func holds(sessionId: String) -> Bool {
        bySession[sessionId] != nil
    }

    func isCommitting(taskId: String) -> Bool {
        bySession.values.contains { $0.taskId == taskId && $0.running }
    }

    private func finished(sessionId: String, id: UUID) {
        if bySession[sessionId]?.id == id { bySession[sessionId]?.running = false }
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
