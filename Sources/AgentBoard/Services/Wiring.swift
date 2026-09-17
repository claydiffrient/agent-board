import AgentBoardBridge
import AgentBoardCore
import AgentBoardRuntime
import AgentBoardServer
import Foundation

@MainActor
enum Wiring {
    static var appSupportDir: URL {
        if let override = ProcessInfo.processInfo.environment[SupportPaths.supportDirEnvKey] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentBoard")
    }

    static var worktreeBase: URL { SupportPaths.worktreeBase() }

    static func makeSupervisor(db: AppDatabase, sleepGuard: SleepGuard? = nil) -> WorkerSupervisor {
        let sink = LateBoundSink()
        let server = BoardServer(
            tokens: StoreTokenResolver(db: db),
            hooks: StoreHookSink(db: db, events: sink),
            tools: ScopedToolHandler(
                worker: WorkerToolHandler(db: db, events: sink, scopedCommits: ScopedCommitRunner()),
                orchestrator: OrchestratorToolHandler(db: db, control: sink, events: sink)
            ),
            resources: CompositeResourceHandler([
                (NoteResourceURI.scheme, NoteResourceHandler(db: db)),
                (BriefingResourceURI.scheme, BriefingResourceHandler(db: db)),
            ]),
            prompts: BriefingPromptHandler()
        )
        let supervisor = WorkerSupervisor(
            db: db,
            runtime: BackgroundSessionRuntime(),
            server: server,
            appSupportDir: appSupportDir,
            worktreeBase: worktreeBase,
            sleepGuard: sleepGuard
        )
        sink.target = supervisor
        return supervisor
    }
}

/// The server is built before the supervisor it reports to; events before `target` is set are dropped.
final class LateBoundSink: BoardEventSink, WorkerControl, @unchecked Sendable {
    private let lock = NSLock()
    private var storedTarget: (any BoardEventSink & WorkerControl)?

    var target: (any BoardEventSink & WorkerControl)? {
        get { lock.withLock { storedTarget } }
        set { lock.withLock { storedTarget = newValue } }
    }

    func notify(projectId: String, title: String, body: String) async {
        await target?.notify(projectId: projectId, title: title, body: body)
    }

    func notify(projectId: String, sessionId: String?, title: String, body: String) async {
        await target?.notify(projectId: projectId, sessionId: sessionId, title: title, body: body)
    }

    func orchestratorTurnEnded(projectId: String, sessionId: String) async {
        await target?.orchestratorTurnEnded(projectId: projectId, sessionId: sessionId)
    }

    func reportQueued(projectId: String) async {
        await target?.reportQueued(projectId: projectId)
    }

    func orchestratorCompacted(projectId: String, sessionId: String, manual: Bool) async {
        await target?.orchestratorCompacted(projectId: projectId, sessionId: sessionId, manual: manual)
    }

    func workerAcknowledgedShutdown(projectId: String, sessionId: String) async {
        await target?.workerAcknowledgedShutdown(projectId: projectId, sessionId: sessionId)
    }

    func workerCompleted(projectId: String, sessionId: String) async {
        await target?.workerCompleted(projectId: projectId, sessionId: sessionId)
    }

    func spawnWorker(taskId: String) async throws -> WorkerSpawn {
        guard let target else { throw SupervisorError.serverNotRunning }
        return try await target.spawnWorker(taskId: taskId)
    }

    func stopWorker(sessionId: String) async throws {
        guard let target else { throw SupervisorError.serverNotRunning }
        try await target.stopWorker(sessionId: sessionId)
    }
}
