import AgentBoardServer
import Foundation

actor RecordingHookSink: HookSink {
    private(set) var events: [(HookEvent, TokenIdentity)] = []
    var decision: HookDecision?

    init(decision: HookDecision? = nil) {
        self.decision = decision
    }

    func setDecision(_ decision: HookDecision?) {
        self.decision = decision
    }

    func handle(_ event: HookEvent, identity: TokenIdentity) async -> HookDecision? {
        events.append((event, identity))
        return decision
    }
}

struct CrashError: Error, CustomStringConvertible {
    var description: String { "database exploded" }
}

actor FakeToolHandler: ToolHandler {
    struct Call: Equatable {
        var name: String
        var arguments: JSONValue
        var identity: TokenIdentity
    }

    private(set) var calls: [Call] = []

    static let workerTools: [ToolDescriptor] = [
        ToolDescriptor(
            name: "get_my_task",
            description: "The task bound to this token",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])])
        ),
        ToolDescriptor(
            name: "log_progress",
            description: "Append progress",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["text": .object(["type": .string("string"), "maxLength": .number(4000)])]),
                "required": .array([.string("text")]),
            ])
        ),
    ]

    static let orchestratorTools: [ToolDescriptor] = workerTools + [
        ToolDescriptor(
            name: "list_tasks",
            description: "Board query",
            inputSchema: .object(["type": .string("object"), "properties": .object(["column": .object(["type": .string("string")])])])
        ),
    ]

    func tools(for identity: TokenIdentity) async -> [ToolDescriptor] {
        switch identity.scope {
        case .worker: return Self.workerTools
        case .orchestrator: return Self.orchestratorTools
        }
    }

    func call(_ name: String, arguments: JSONValue, identity: TokenIdentity) async throws -> ToolResult {
        calls.append(Call(name: name, arguments: arguments, identity: identity))
        switch name {
        case "echo":
            return .json(arguments)
        case "soft_error":
            return ToolResult(text: "handled softly", isError: true)
        case "fail":
            throw ToolError("task 42 is not assignable")
        case "crash":
            throw CrashError()
        default:
            throw ToolError("Unknown tool: \(name)")
        }
    }
}
