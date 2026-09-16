import AgentBoardServer
import Foundation

public struct ScopedToolHandler: ToolHandler {
    private let worker: any ToolHandler
    private let orchestrator: any ToolHandler
    private let reviewer: any ToolHandler

    public init(worker: any ToolHandler, orchestrator: any ToolHandler, reviewer: any ToolHandler) {
        self.worker = worker
        self.orchestrator = orchestrator
        self.reviewer = reviewer
    }

    public func tools(for identity: TokenIdentity) async -> [ToolDescriptor] {
        await handler(for: identity).tools(for: identity)
    }

    public func call(_ name: String, arguments: JSONValue, identity: TokenIdentity) async throws -> ToolResult {
        try await handler(for: identity).call(name, arguments: arguments, identity: identity)
    }

    private func handler(for identity: TokenIdentity) -> any ToolHandler {
        switch identity.scope {
        case .worker: return worker
        case .orchestrator: return orchestrator
        case .reviewer: return reviewer
        }
    }
}
