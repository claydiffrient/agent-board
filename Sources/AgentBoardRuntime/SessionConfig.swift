import Foundation

public struct SessionConfigFiles: Sendable, Equatable {
    public var settingsURL: URL
    public var mcpConfigURL: URL

    public init(settingsURL: URL, mcpConfigURL: URL) {
        self.settingsURL = settingsURL
        self.mcpConfigURL = mcpConfigURL
    }
}

/// A serialized JSON object (`{...}`), validated when written.
public struct JSONObjectString: Sendable, Equatable, ExpressibleByStringLiteral {
    public var rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    func object() throws -> [String: Any] {
        guard let data = rawValue.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw AgentRuntimeError("expected a JSON object, got: \(rawValue)")
        }
        return object
    }
}

public enum SessionConfigWriter {
    public static let httpHookEvents = ["UserPromptSubmit", "PostToolUse", "Notification", "Stop", "SessionEnd"]
    /// `PreToolUse` is the app-side half of the push/PR block (§8). Matched to `Bash` so the
    /// round trip is not paid on every tool call.
    public static let guardedPreToolUseMatcher = "Bash"

    public static func settingsURL(configDir: URL, configId: String) -> URL {
        configDir.appendingPathComponent("settings-\(configId).json")
    }

    public static func mcpConfigURL(configDir: URL, configId: String) -> URL {
        configDir.appendingPathComponent("mcp-\(configId).json")
    }

    public static func hookURL(port: Int, token: String) -> String {
        "http://127.0.0.1:\(port)/hooks?token=\(token)"
    }

    public static func mcpURL(port: Int) -> String {
        "http://127.0.0.1:\(port)/mcp"
    }

    @discardableResult
    public static func write(
        configDir: URL,
        configId: String,
        port: Int,
        token: String,
        autoModeJSON: String? = nil,
        extraMcpServers: [String: JSONObjectString]? = nil
    ) throws -> SessionConfigFiles {
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)

        let settings = try settingsObject(port: port, token: token, autoModeJSON: autoModeJSON)
        let mcp = try mcpConfigObject(port: port, token: token, extraMcpServers: extraMcpServers)

        let files = SessionConfigFiles(
            settingsURL: settingsURL(configDir: configDir, configId: configId),
            mcpConfigURL: mcpConfigURL(configDir: configDir, configId: configId)
        )
        try writeJSON(settings, to: files.settingsURL)
        try writeJSON(mcp, to: files.mcpConfigURL)
        return files
    }

    static func settingsObject(port: Int, token: String, autoModeJSON: String?) throws -> [String: Any] {
        let url = hookURL(port: port, token: token)
        let httpHook: [String: Any] = ["type": "http", "url": url, "timeout": 5]
        let curlHook: [String: Any] = [
            "type": "command",
            "command": "curl -s -m 5 -X POST -H 'Content-Type: application/json' --data-binary @- '\(url)' >/dev/null",
        ]

        var hooks: [String: Any] = [
            "SessionStart": [["hooks": [curlHook]]],
            "PreToolUse": [["matcher": guardedPreToolUseMatcher, "hooks": [httpHook]]],
        ]
        for event in httpHookEvents {
            hooks[event] = [["hooks": [httpHook]]]
        }

        var settings: [String: Any] = ["hooks": hooks]
        if let autoModeJSON {
            settings["autoMode"] = try JSONObjectString(autoModeJSON).object()
        }
        return settings
    }

    static func mcpConfigObject(
        port: Int,
        token: String,
        extraMcpServers: [String: JSONObjectString]?
    ) throws -> [String: Any] {
        var servers: [String: Any] = [
            "agent-board": [
                "type": "http",
                "url": mcpURL(port: port),
                "headers": ["Authorization": "Bearer \(token)"],
            ] as [String: Any],
        ]
        for (name, json) in extraMcpServers ?? [:] where name != "agent-board" {
            servers[name] = try json.object()
        }
        return ["mcpServers": servers]
    }

    private static func writeJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: url, options: .atomic)
    }
}
