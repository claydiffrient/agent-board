import AgentBoardCore
import Foundation

public protocol BoardEventSink: Sendable {
    /// `projectId` is carried so the banner can name its project; with several projects registered
    /// a bare title does not say where the agent is.
    func notify(projectId: String, title: String, body: String) async
    /// The same banner, naming the session it is about so a click can land on it. Declared here
    /// rather than only in the extension so a conformer's own implementation actually wins.
    func notify(projectId: String, sessionId: String?, title: String, body: String) async
    func orchestratorTurnEnded(projectId: String, sessionId: String) async
    func reportQueued(projectId: String) async
    /// A compaction finished on the orchestrator. `manual` separates the `/compact` Agent Board or
    /// the human typed from Claude Code's own auto-compaction, whose turn continues by itself and
    /// must not be interrupted.
    func orchestratorCompacted(projectId: String, sessionId: String, manual: Bool) async
    /// The worker has recorded its resume note and is waiting to be stopped. Agent Board owns the
    /// rest: stop the session, terminate the row as an orderly shutdown, put the task back in ready.
    func workerAcknowledgedShutdown(projectId: String, sessionId: String) async
    /// The worker has filed its report and the task is in review. `Board.complete` cannot reach a
    /// runtime, so stopping the agent that is now doing nothing is the supervisor's to do.
    func workerCompleted(projectId: String, sessionId: String) async
}

extension BoardEventSink {
    public func workerCompleted(projectId: String, sessionId: String) async {}
}

extension BoardEventSink {
    public func notify(projectId: String, sessionId: String?, title: String, body: String) async {
        await notify(projectId: projectId, title: title, body: body)
    }
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
    /// The single acceptance path, whoever triggered it: the board accept, the newly-ready
    /// announcement, the grant revocation and the worktree removal. A no-review completion and a
    /// rostered reviewer's approval both come through here rather than repeating any of it.
    func accept(taskId: String, acceptedBy: TaskAcceptance) async throws
}

public struct ClosureBoardEventSink: BoardEventSink {
    private let onNotify: @Sendable (String, String, String) async -> Void
    private let onOrchestratorTurnEnded: @Sendable (String, String) async -> Void
    private let onReportQueued: @Sendable (String) async -> Void
    private let onOrchestratorCompacted: @Sendable (String, String, Bool) async -> Void
    private let onWorkerAcknowledgedShutdown: @Sendable (String, String) async -> Void
    private let onWorkerCompleted: @Sendable (String, String) async -> Void

    public init(
        notify: @escaping @Sendable (_ projectId: String, _ title: String, _ body: String) async -> Void = { _, _, _ in },
        orchestratorTurnEnded: @escaping @Sendable (_ projectId: String, _ sessionId: String) async -> Void = { _, _ in },
        reportQueued: @escaping @Sendable (_ projectId: String) async -> Void = { _ in },
        orchestratorCompacted: @escaping @Sendable (_ projectId: String, _ sessionId: String, _ manual: Bool) async -> Void = { _, _, _ in },
        workerAcknowledgedShutdown: @escaping @Sendable (_ projectId: String, _ sessionId: String) async -> Void = { _, _ in },
        workerCompleted: @escaping @Sendable (_ projectId: String, _ sessionId: String) async -> Void = { _, _ in }
    ) {
        onNotify = notify
        onOrchestratorTurnEnded = orchestratorTurnEnded
        onReportQueued = reportQueued
        onOrchestratorCompacted = orchestratorCompacted
        onWorkerAcknowledgedShutdown = workerAcknowledgedShutdown
        onWorkerCompleted = workerCompleted
    }

    public func notify(projectId: String, title: String, body: String) async {
        await onNotify(projectId, title, body)
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

    public func workerCompleted(projectId: String, sessionId: String) async {
        await onWorkerCompleted(projectId, sessionId)
    }
}
