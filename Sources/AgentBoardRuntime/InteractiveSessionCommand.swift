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
    public var addDirs: [String]
    public var disallowedTools: [String]
    public var projectsRoot: URL
    public var invocation: ClaudeInvocation

    public init(sessionId: String, cwd: URL, configFiles: SessionConfigFiles, appendSystemPrompt: String,
                model: String? = nil, strictMcpConfig: Bool = false, addDirs: [String] = [],
                disallowedTools: [String] = [], projectsRoot: URL = ClaudeProjectPaths.defaultProjectsRoot,
                invocation: ClaudeInvocation = .installed()) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.configFiles = configFiles
        self.appendSystemPrompt = appendSystemPrompt
        self.model = model
        self.strictMcpConfig = strictMcpConfig
        self.addDirs = addDirs
        self.disallowedTools = disallowedTools
        self.projectsRoot = projectsRoot
        self.invocation = invocation
    }

    public var transcriptExists: Bool {
        FileManager.default.fileExists(
            atPath: ClaudeProjectPaths.transcriptURL(forCwd: cwd.path, sessionId: sessionId, projectsRoot: projectsRoot).path
        )
    }

    public var executable: String { invocation.executable }

    public func arguments(resume: Bool? = nil) -> [String] {
        var args = invocation.prefix
        args += (resume ?? transcriptExists) ? ["--resume", sessionId] : ["--session-id", sessionId]
        args += ["--mcp-config", configFiles.mcpConfigURL.path, "--settings", configFiles.settingsURL.path]
        if strictMcpConfig { args.append("--strict-mcp-config") }
        args += ["--append-system-prompt", appendSystemPrompt]
        if let model { args += ["--model", model] }
        if !addDirs.isEmpty { args += ["--add-dir"] + addDirs }
        if !disallowedTools.isEmpty { args += ["--disallowedTools"] + disallowedTools }
        return args
    }
}

/// How `claude` is started in a PTY. `installed()` is the real CLI; a test substitutes a script.
public struct ClaudeInvocation: Sendable, Equatable {
    public var executable: String
    public var prefix: [String]

    public init(executable: String, prefix: [String] = []) {
        self.executable = executable
        self.prefix = prefix
    }

    public static func installed() -> ClaudeInvocation {
        let found = ClaudeCLI.invocation()
        return ClaudeInvocation(executable: found.executable, prefix: found.prefix)
    }
}
