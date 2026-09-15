import Foundation

public protocol BoardEventSink: Sendable {
    func notify(title: String, body: String) async
    func orchestratorTurnEnded(projectId: String, sessionId: String) async
    func reportQueued(projectId: String) async
    /// A compaction finished on the orchestrator. `manual` separates the `/compact` Agent Board or
    /// the human typed from Claude Code's own auto-compaction, whose turn continues by itself and
    /// must not be interrupted.
    func orchestratorCompacted(projectId: String, sessionId: String, manual: Bool) async
    /// The worker has recorded its resume note and is waiting to be stopped. Agent Board owns the
    /// rest: stop the session, terminate the row as an orderly shutdown, put the task back in ready.
    func workerAcknowledgedShutdown(projectId: String, sessionId: String) async
}

public protocol WorkerControl: Sendable {
    /// The caller has already passed `Board.requestSpawn`; returns the new session id.
    func spawnWorker(taskId: String) async throws -> String
    func stopWorker(sessionId: String) async throws
}

public struct ClosureBoardEventSink: BoardEventSink {
    private let onNotify: @Sendable (String, String) async -> Void
    private let onOrchestratorTurnEnded: @Sendable (String, String) async -> Void
    private let onReportQueued: @Sendable (String) async -> Void
    private let onOrchestratorCompacted: @Sendable (String, String, Bool) async -> Void
    private let onWorkerAcknowledgedShutdown: @Sendable (String, String) async -> Void

    public init(
        notify: @escaping @Sendable (_ title: String, _ body: String) async -> Void = { _, _ in },
        orchestratorTurnEnded: @escaping @Sendable (_ projectId: String, _ sessionId: String) async -> Void = { _, _ in },
        reportQueued: @escaping @Sendable (_ projectId: String) async -> Void = { _ in },
        orchestratorCompacted: @escaping @Sendable (_ projectId: String, _ sessionId: String, _ manual: Bool) async -> Void = { _, _, _ in },
        workerAcknowledgedShutdown: @escaping @Sendable (_ projectId: String, _ sessionId: String) async -> Void = { _, _ in }
    ) {
        onNotify = notify
        onOrchestratorTurnEnded = orchestratorTurnEnded
        onReportQueued = reportQueued
        onOrchestratorCompacted = orchestratorCompacted
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

    public func orchestratorCompacted(projectId: String, sessionId: String, manual: Bool) async {
        await onOrchestratorCompacted(projectId, sessionId, manual)
    }

    public func workerAcknowledgedShutdown(projectId: String, sessionId: String) async {
        await onWorkerAcknowledgedShutdown(projectId, sessionId)
    }
}
