import Foundation

public protocol BoardEventSink: Sendable {
    func notify(title: String, body: String) async
    func orchestratorTurnEnded(projectId: String, sessionId: String) async
    func reportQueued(projectId: String) async
    /// The worker has recorded its resume note and is waiting to be stopped. Agent Board owns the
    /// rest: stop the session, terminate the row as an orderly shutdown, put the task back in ready.
    func workerAcknowledgedShutdown(projectId: String, sessionId: String) async
}

/// What `spawn_worker` can promise by the time it answers: the worktree is on disk and the task is
/// claimed. Preparing the repository and starting the agent carry on afterwards, so no Claude
/// session id exists yet.
public struct WorkerSpawn: Sendable, Equatable {
    /// The `agent_session` row holding the slot during setup. Claude's own session id replaces it
    /// once the agent registers, so this identifies the spawn, not the session that comes out of it.
    public var setupSessionId: String
    /// The worker's working directory: its own worktree, or the project's checkout under `shared`.
    public var worktreePath: String
    public var branch: String
    /// True when the worker runs in the project's own checkout rather than a worktree of its own.
    public var sharesCheckout: Bool
    /// Raised before any git work, so a worktree path a repository's setup cannot survive is named
    /// while the orchestrator can still act on it rather than after setup has already failed.
    public var warnings: [String]

    public init(
        setupSessionId: String, worktreePath: String, branch: String, sharesCheckout: Bool = false,
        warnings: [String] = []
    ) {
        self.setupSessionId = setupSessionId
        self.worktreePath = worktreePath
        self.branch = branch
        self.sharesCheckout = sharesCheckout
        self.warnings = warnings
    }
}

public protocol WorkerControl: Sendable {
    /// The caller has already passed `Board.requestSpawn`. Returns once the worktree exists and the
    /// session row is written, with setup still running.
    func spawnWorker(taskId: String) async throws -> WorkerSpawn
    func stopWorker(sessionId: String) async throws
}

public struct ClosureBoardEventSink: BoardEventSink {
    private let onNotify: @Sendable (String, String) async -> Void
    private let onOrchestratorTurnEnded: @Sendable (String, String) async -> Void
    private let onReportQueued: @Sendable (String) async -> Void
    private let onWorkerAcknowledgedShutdown: @Sendable (String, String) async -> Void

    public init(
        notify: @escaping @Sendable (_ title: String, _ body: String) async -> Void = { _, _ in },
        orchestratorTurnEnded: @escaping @Sendable (_ projectId: String, _ sessionId: String) async -> Void = { _, _ in },
        reportQueued: @escaping @Sendable (_ projectId: String) async -> Void = { _ in },
        workerAcknowledgedShutdown: @escaping @Sendable (_ projectId: String, _ sessionId: String) async -> Void = { _, _ in }
    ) {
        onNotify = notify
        onOrchestratorTurnEnded = orchestratorTurnEnded
        onReportQueued = reportQueued
        onWorkerAcknowledgedShutdown = workerAcknowledgedShutdown
    }

    public func notify(title: String, body: String) async {
        await onNotify(title, body)
    }

    public func orchestratorTurnEnded(projectId: String, sessionId: String) async {
        await onOrchestratorTurnEnded(projectId, sessionId)
    }

    public func reportQueued(projectId: String) async {
        await onReportQueued(projectId)
    }

    public func workerAcknowledgedShutdown(projectId: String, sessionId: String) async {
        await onWorkerAcknowledgedShutdown(projectId, sessionId)
    }
}
