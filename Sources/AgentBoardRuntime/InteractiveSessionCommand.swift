import Foundation

/// The foreground orchestrator process the app runs inside its own PTY (SPEC §9).
/// Unlike workers it is not `--bg`, so `--session-id` pins the id and `--resume` restores it.
public struct InteractiveSessionCommand: Sendable, Equatable {
    public var sessionId: String
    public var cwd: URL
    public var configFiles: SessionConfigFiles
    public var appendSystemPrompt: String
    public var model: String?
    public var strictMcpConfig: Bool

    public init(sessionId: String, cwd: URL, configFiles: SessionConfigFiles, appendSystemPrompt: String,
                model: String? = nil, strictMcpConfig: Bool = false) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.configFiles = configFiles
        self.appendSystemPrompt = appendSystemPrompt
        self.model = model
        self.strictMcpConfig = strictMcpConfig
    }

    public var transcriptExists: Bool {
        FileManager.default.fileExists(atPath: ClaudeProjectPaths.transcriptURL(forCwd: cwd.path, sessionId: sessionId).path)
    }

    public var executable: String { ClaudeCLI.invocation().executable }

    public func arguments(resume: Bool? = nil) -> [String] {
        var args = ClaudeCLI.invocation().prefix
        args += (resume ?? transcriptExists) ? ["--resume", sessionId] : ["--session-id", sessionId]
        args += ["--mcp-config", configFiles.mcpConfigURL.path, "--settings", configFiles.settingsURL.path]
        if strictMcpConfig { args.append("--strict-mcp-config") }
        args += ["--append-system-prompt", appendSystemPrompt]
        if let model { args += ["--model", model] }
        return args
    }
}
