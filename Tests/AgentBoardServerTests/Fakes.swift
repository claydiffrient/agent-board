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
        case .worker, .reviewer: return Self.workerTools
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

actor FakeResourceHandler: ResourceHandler {
    private(set) var reads: [String] = []
    private var bodies: [String: String] = [:]

    func put(uri: String, body: String) {
        bodies[uri] = body
    }

    func resources(for identity: TokenIdentity) async throws -> [ResourceDescriptor] {
        [
            ResourceDescriptor(
                uri: "note://\(identity.projectId)/n1",
                name: "Build gotchas",
                description: "2 sections: The trap · What to do. Version 3, updated 2026-09-14.",
                mimeType: "application/json"
            ),
        ]
    }

    func read(_ uri: String, identity: TokenIdentity) async throws -> [ResourceContents] {
        reads.append(uri)
        guard let body = bodies[uri] else {
            throw ResourceError(uri: uri, message: "No note for \(uri).")
        }
        return [ResourceContents(uri: uri, mimeType: "application/json", text: body)]
    }
}

actor FakePromptHandler: PromptHandler {
    private(set) var gets: [String] = []

    func prompts(for identity: TokenIdentity) async -> [PromptDescriptor] {
        [
            PromptDescriptor(
                name: "worker_protocol",
                title: "Worker protocol",
                description: "How a worker reports",
                arguments: []
            ),
        ]
    }

    func get(_ name: String, arguments: [String: String], identity: TokenIdentity) async throws -> PromptResult {
        gets.append(name)
        guard name == "worker_protocol" else { throw PromptError("Unknown prompt: \(name)") }
        return PromptResult(description: "How a worker reports", messages: [PromptMessage(text: "Commit, then report.")])
    }
}
