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
        let server = BoardServer(
            tokens: StoreTokenResolver(db: db),
            hooks: StoreHookSink(db: db),
            tools: WorkerToolHandler(db: db)
        )
        return WorkerSupervisor(
            db: db,
            runtime: BackgroundSessionRuntime(),
            server: server,
            appSupportDir: appSupportDir
        )
    }
}
