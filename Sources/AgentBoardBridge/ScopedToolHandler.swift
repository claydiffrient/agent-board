import AgentBoardServer
import Foundation

public struct ScopedToolHandler: ToolHandler {
    private let worker: any ToolHandler
    private let orchestrator: any ToolHandler
    private let reviewer: any ToolHandler
    private let coordinator: any ToolHandler
    private let triager: any ToolHandler

    /// With no `coordinator` or `triager` handler wired, that grant is offered no tools and refused every call.
    public init(
        worker: any ToolHandler, orchestrator: any ToolHandler, reviewer: any ToolHandler,
        coordinator: (any ToolHandler)? = nil, triager: (any ToolHandler)? = nil
    ) {
        self.worker = worker
        self.orchestrator = orchestrator
        self.reviewer = reviewer
        self.coordinator = coordinator ?? NoToolHandler()
        self.triager = triager ?? NoToolHandler()
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
        case .coordinator: return coordinator
        case .triager: return triager
        }
    }
}

private struct NoToolHandler: ToolHandler {
    func tools(for identity: TokenIdentity) async -> [ToolDescriptor] { [] }

    func call(_ name: String, arguments: JSONValue, identity: TokenIdentity) async throws -> ToolResult {
        throw ToolError("Unknown tool: \(name)")
    }
}
