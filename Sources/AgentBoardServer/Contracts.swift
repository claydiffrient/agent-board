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
    public var notificationType: String?
    public var notificationMessage: String?
    public var lastAssistantMessage: String?
    /// `PreCompact`: "manual" for `/compact`, "auto" for the context-window trigger.
    public var compactTrigger: String?
    /// `SubagentStop`: the agent name, e.g. "Explore".
    public var agentType: String?
    public var rawJSON: String
    public var receivedAt: Date

    public init(name: String, sessionId: String, transcriptPath: String? = nil, cwd: String? = nil, toolName: String? = nil,
                toolCommand: String? = nil, notificationType: String? = nil, notificationMessage: String? = nil,
                lastAssistantMessage: String? = nil, compactTrigger: String? = nil, agentType: String? = nil,
                rawJSON: String, receivedAt: Date = Date()) {
        self.name = name
        self.sessionId = sessionId
        self.transcriptPath = transcriptPath
        self.cwd = cwd
        self.toolName = toolName
        self.toolCommand = toolCommand
        self.notificationType = notificationType
        self.notificationMessage = notificationMessage
        self.lastAssistantMessage = lastAssistantMessage
        self.compactTrigger = compactTrigger
        self.agentType = agentType
        self.rawJSON = rawJSON
        self.receivedAt = receivedAt
    }
}

/// What Agent Board sends back on a hook: a `PreToolUse` verdict, or context injected into the
/// session. Decided in Agent Board's own process, so a verdict holds under any `--permission-mode`;
/// see §8.
public struct HookDecision: Sendable, Equatable {
    public var permissionDecision: String?
    public var reason: String?
    public var additionalContext: String?

    public init(permissionDecision: String? = nil, reason: String? = nil, additionalContext: String? = nil) {
        self.permissionDecision = permissionDecision
        self.reason = reason
        self.additionalContext = additionalContext
    }

    public static func deny(_ reason: String) -> HookDecision {
        HookDecision(permissionDecision: "deny", reason: reason)
    }

    /// Context only — no verdict, so the body carries no `decision` key and cannot be read as a block.
    public static func context(_ text: String) -> HookDecision {
        HookDecision(additionalContext: text)
    }

    /// A verdict is sent in both the current `hookSpecificOutput` shape and the legacy
    /// `decision`/`reason` pair, so the deny lands whichever one the installed CLI reads.
    public func responseBody(hookEventName: String) -> [String: Any] {
        var specific: [String: Any] = ["hookEventName": hookEventName]
        var body: [String: Any] = [:]
        if let permissionDecision {
            specific["permissionDecision"] = permissionDecision
            specific["permissionDecisionReason"] = reason ?? ""
            body["decision"] = permissionDecision == "deny" ? "block" : "approve"
            body["reason"] = reason ?? ""
        }
        if let additionalContext {
            specific["additionalContext"] = additionalContext
        }
        body["hookSpecificOutput"] = specific
        return body
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

    public static func json(_ value: JSONValue) -> ToolResult {
        let data = (try? JSONEncoder().encode(value)) ?? Data("null".utf8)
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
