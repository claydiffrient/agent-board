import AgentBoardBridge
import AgentBoardCore
import AgentBoardRuntime
import AgentBoardServer
import Foundation

@MainActor
enum Wiring {
    static var appSupportDir: URL {
        if let override = ProcessInfo.processInfo.environment["AGENTBOARD_SUPPORT_DIR"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentBoard")
    }

    static func makeSupervisor(db: AppDatabase) -> WorkerSupervisor {
        let sink = LateBoundSink()
        let server = BoardServer(
            tokens: StoreTokenResolver(db: db),
            hooks: StoreHookSink(db: db, events: sink),
            tools: ScopedToolHandler(
                worker: WorkerToolHandler(db: db, events: sink),
                orchestrator: OrchestratorToolHandler(db: db, control: sink, events: sink)
            )
        )
        let supervisor = WorkerSupervisor(
            db: db,
            runtime: BackgroundSessionRuntime(),
            server: server,
            appSupportDir: appSupportDir
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

    func notify(title: String, body: String) async {
        await target?.notify(title: title, body: body)
    }

    func orchestratorTurnEnded(projectId: String, sessionId: String) async {
        await target?.orchestratorTurnEnded(projectId: projectId, sessionId: sessionId)
    }

    func reportQueued(projectId: String) async {
        await target?.reportQueued(projectId: projectId)
    }

    func workerAcknowledgedShutdown(projectId: String, sessionId: String) async {
        await target?.workerAcknowledgedShutdown(projectId: projectId, sessionId: sessionId)
    }

    func spawnWorker(taskId: String) async throws -> String {
        guard let target else { throw SupervisorError.serverNotRunning }
        return try await target.spawnWorker(taskId: taskId)
    }

    func stopWorker(sessionId: String) async throws {
        guard let target else { throw SupervisorError.serverNotRunning }
        try await target.stopWorker(sessionId: sessionId)
    }
}
