import Foundation

public enum TokenScope: String, Sendable, Codable {
    case worker
    case orchestrator
}

public struct TokenIdentity: Sendable, Equatable {
    public var token: String
    public var scope: TokenScope
    public var projectId: String
    public var sessionId: String?
    public var taskId: String?

    public init(token: String, scope: TokenScope, projectId: String, sessionId: String? = nil, taskId: String? = nil) {
        self.token = token
        self.scope = scope
        self.projectId = projectId
        self.sessionId = sessionId
        self.taskId = taskId
    }
}

public protocol TokenResolver: Sendable {
    func resolve(token: String) async -> TokenIdentity?
}

public struct HookEvent: Sendable {
    public var name: String
    public var sessionId: String
    public var transcriptPath: String?
    public var cwd: String?
    public var toolName: String?
    public var toolCommand: String?
    /// The file a write tool is about to touch, when the tool names one.
    public var toolFilePath: String?
    public var notificationType: String?
    public var notificationMessage: String?
    public var lastAssistantMessage: String?
    public var rawJSON: String
    public var receivedAt: Date

    public init(name: String, sessionId: String, transcriptPath: String? = nil, cwd: String? = nil, toolName: String? = nil,
                toolCommand: String? = nil, toolFilePath: String? = nil, notificationType: String? = nil,
                notificationMessage: String? = nil,
                lastAssistantMessage: String? = nil, rawJSON: String, receivedAt: Date = Date()) {
        self.name = name
        self.sessionId = sessionId
        self.transcriptPath = transcriptPath
        self.cwd = cwd
        self.toolName = toolName
        self.toolCommand = toolCommand
        self.toolFilePath = toolFilePath
        self.notificationType = notificationType
        self.notificationMessage = notificationMessage
        self.lastAssistantMessage = lastAssistantMessage
        self.rawJSON = rawJSON
        self.receivedAt = receivedAt
    }
}

/// A `PreToolUse` verdict. Agent Board decides this in its own process, so it holds under any
/// `--permission-mode`; see §8.
public struct HookDecision: Sendable, Equatable {
    public var permissionDecision: String
    public var reason: String

    public init(permissionDecision: String, reason: String) {
        self.permissionDecision = permissionDecision
        self.reason = reason
    }

    public static func deny(_ reason: String) -> HookDecision {
        HookDecision(permissionDecision: "deny", reason: reason)
    }

    /// Both the current `hookSpecificOutput` shape and the legacy `decision`/`reason` pair, so the
    /// deny lands whichever one the installed CLI reads.
    public func responseBody(hookEventName: String) -> [String: Any] {
        [
            "hookSpecificOutput": [
                "hookEventName": hookEventName,
                "permissionDecision": permissionDecision,
                "permissionDecisionReason": reason,
            ],
            "decision": permissionDecision == "deny" ? "block" : "approve",
            "reason": reason,
        ]
    }
}

/// Must return fast; PostToolUse fires on every tool call and the agent waits on the response.
public protocol HookSink: Sendable {
    func handle(_ event: HookEvent, identity: TokenIdentity) async -> HookDecision?
}

public indirect enum JSONValue: Sendable, Equatable, Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let b = try? container.decode(Bool.self) { self = .bool(b); return }
        if let n = try? container.decode(Double.self) { self = .number(n); return }
        if let s = try? container.decode(String.self) { self = .string(s); return }
        if let a = try? container.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? container.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        case .bool(let b): try container.encode(b)
        case .null: try container.encodeNil()
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var numberValue: Double? { if case .number(let n) = self { return n }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    public subscript(key: String) -> JSONValue? { objectValue?[key] }
}

public struct ToolDescriptor: Sendable, Equatable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct ToolResult: Sendable, Equatable {
    public var text: String
    public var isError: Bool

    public init(text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }

    /// Keys are sorted so the same value always encodes to the same bytes; a resource body and the
    /// tool result it mirrors have to compare equal.
    public static func json(_ value: JSONValue) -> ToolResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(value)) ?? Data("null".utf8)
        return ToolResult(text: String(decoding: data, as: UTF8.self))
    }
}

public struct ToolError: Error, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

/// Tool list is rendered per identity, so a worker never sees orchestrator tools.
public protocol ToolHandler: Sendable {
    func tools(for identity: TokenIdentity) async -> [ToolDescriptor]
    func call(_ name: String, arguments: JSONValue, identity: TokenIdentity) async throws -> ToolResult
}

/// One entry in a `resources/list` result. `title`, `size` and `annotations` are part of the MCP
/// shape but are not served here.
public struct ResourceDescriptor: Sendable, Equatable {
    public var uri: String
    public var name: String
    public var description: String
    public var mimeType: String

    public init(uri: String, name: String, description: String, mimeType: String) {
        self.uri = uri
        self.name = name
        self.description = description
        self.mimeType = mimeType
    }
}

public struct ResourceContents: Sendable, Equatable {
    public var uri: String
    public var mimeType: String
    public var text: String

    public init(uri: String, mimeType: String, text: String) {
        self.uri = uri
        self.mimeType = mimeType
        self.text = text
    }
}

public struct PromptArgumentDescriptor: Sendable, Equatable {
    public var name: String
    public var description: String
    public var required: Bool

    public init(name: String, description: String, required: Bool) {
        self.name = name
        self.description = description
        self.required = required
    }
}

public struct PromptDescriptor: Sendable, Equatable {
    public var name: String
    public var title: String
    public var description: String
    public var arguments: [PromptArgumentDescriptor]

    public init(name: String, title: String, description: String, arguments: [PromptArgumentDescriptor]) {
        self.name = name
        self.title = title
        self.description = description
        self.arguments = arguments
    }
}

public struct PromptMessage: Sendable, Equatable {
    public enum Role: String, Sendable, Equatable {
        case user
        case assistant
    }

    public var role: Role
    public var text: String

    public init(role: Role = .user, text: String) {
        self.role = role
        self.text = text
    }
}

/// Carried to the client as JSON-RPC -32002 with the offending uri in `data`.
public struct ResourceError: Error, Sendable {
    public var uri: String
    public var message: String

    public init(uri: String, message: String) {
        self.uri = uri
        self.message = message
    }
}

/// Resources are listed per identity for the same reason tools are: a token sees its own project.
public protocol ResourceHandler: Sendable {
    func resources(for identity: TokenIdentity) async throws -> [ResourceDescriptor]
    func read(_ uri: String, identity: TokenIdentity) async throws -> [ResourceContents]
}

public struct PromptResult: Sendable, Equatable {
    public var description: String
    public var messages: [PromptMessage]

    public init(description: String, messages: [PromptMessage]) {
        self.description = description
        self.messages = messages
    }
}

/// An unknown prompt name or a missing required argument. Surfaces as JSON-RPC -32602 per the
/// prompts specification, not as a result with `isError` — a prompt has no equivalent of a tool's
/// soft failure.
public struct PromptError: Error, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

/// Prompt list is rendered per identity, in the same way the tool list is.
public protocol PromptHandler: Sendable {
    func prompts(for identity: TokenIdentity) async -> [PromptDescriptor]
    func get(_ name: String, arguments: [String: String], identity: TokenIdentity) async throws -> PromptResult
}
