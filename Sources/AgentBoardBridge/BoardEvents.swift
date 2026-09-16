import AgentBoardCore
import Foundation

public protocol BoardEventSink: Sendable {
    func notify(title: String, body: String) async
    func orchestratorTurnEnded(projectId: String, sessionId: String) async
    func reportQueued(projectId: String) async
}

public protocol WorkerControl: Sendable {
    /// The caller has already passed `Board.requestSpawn`; returns the new session id.
    func spawnWorker(taskId: String) async throws -> String
    func stopWorker(sessionId: String) async throws
    /// The single acceptance path, whoever triggered it: the board accept, the newly-ready
    /// announcement, the grant revocation and the worktree removal. A no-review completion and a
    /// rostered reviewer's approval both come through here rather than repeating any of it.
    func accept(taskId: String, acceptedBy: TaskAcceptance) async throws
}

public struct ClosureBoardEventSink: BoardEventSink {
    private let onNotify: @Sendable (String, String) async -> Void
    private let onOrchestratorTurnEnded: @Sendable (String, String) async -> Void
    private let onReportQueued: @Sendable (String) async -> Void

    public init(
        notify: @escaping @Sendable (_ title: String, _ body: String) async -> Void = { _, _ in },
        orchestratorTurnEnded: @escaping @Sendable (_ projectId: String, _ sessionId: String) async -> Void = { _, _ in },
        reportQueued: @escaping @Sendable (_ projectId: String) async -> Void = { _ in }
    ) {
        onNotify = notify
        onOrchestratorTurnEnded = orchestratorTurnEnded
        onReportQueued = reportQueued
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
}
