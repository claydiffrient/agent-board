import Foundation

public struct SpawnRequest: Sendable {
    public var cwd: URL
    public var name: String
    public var prompt: String
    public var configFiles: SessionConfigFiles
    public var permissionMode: String
    public var disallowedTools: [String]
    public var appendSystemPrompt: String?
    public var model: String?

    public static let defaultDisallowedTools = ["Bash(git push*)", "Bash(gh pr create*)", "Bash(gh pr merge*)"]

    /// Layered onto the default for a rostered reviewer, which reviews and changes nothing (SPEC §5.1).
    /// Build output is not a checkout change, so builds and tests stay allowed.
    public static let reviewerDisallowedTools = [
        "Edit", "MultiEdit", "Write", "NotebookEdit",
        "Bash(git commit*)", "Bash(git checkout*)", "Bash(git switch*)", "Bash(git reset*)",
        "Bash(git rebase*)", "Bash(git merge*)", "Bash(git stash*)", "Bash(git add*)", "Bash(git rm*)",
        "Bash(git restore*)", "Bash(git clean*)", "Bash(git cherry-pick*)", "Bash(git revert*)",
        "Bash(git pull*)", "Bash(git am*)", "Bash(git apply*)",
        "Bash(rm *)", "Bash(mv *)",
    ]

    public init(
        cwd: URL,
        name: String,
        prompt: String,
        configFiles: SessionConfigFiles,
        permissionMode: String = "auto",
        disallowedTools: [String] = SpawnRequest.defaultDisallowedTools,
        appendSystemPrompt: String? = nil,
        model: String? = nil
    ) {
        self.cwd = cwd
        self.name = name
        self.prompt = prompt
        self.configFiles = configFiles
        self.permissionMode = permissionMode
        self.disallowedTools = disallowedTools
        self.appendSystemPrompt = appendSystemPrompt
        self.model = model
    }
}

public struct SpawnedAgent: Sendable, Equatable {
    public var shortId: String
    public var sessionId: String

    public init(shortId: String, sessionId: String) {
        self.shortId = shortId
        self.sessionId = sessionId
    }
}

public protocol AgentRuntime: Sendable {
    func spawn(_ request: SpawnRequest) async throws -> SpawnedAgent
    /// The caller must have rewritten the session's config files for the current port first.
    /// The prompt is sent as the first turn; without one a resumed background session waits for input forever.
    func resume(sessionId: String, cwd: URL, prompt: String) async throws -> SpawnedAgent
    func stop(shortId: String) async throws
    func remove(shortId: String) async throws
    func listSessions() async throws -> [AgentInfo]
    func attachCommand(shortId: String) -> (executable: String, arguments: [String])
}

public struct BackgroundSessionRuntime: AgentRuntime {
    public var registrationTimeout: TimeInterval

    public init(registrationTimeout: TimeInterval = 10) {
        self.registrationTimeout = registrationTimeout
    }

    /// The prompt is positional and must come first: `--disallowedTools` is variadic and would swallow it.
    public static func arguments(for request: SpawnRequest) -> [String] {
        var args = [
            request.prompt,
            "--bg",
            "-n", request.name,
            "--permission-mode", request.permissionMode,
            "--strict-mcp-config",
            "--mcp-config", request.configFiles.mcpConfigURL.path,
            "--settings", request.configFiles.settingsURL.path,
        ]
        if let appendSystemPrompt = request.appendSystemPrompt {
            args += ["--append-system-prompt", appendSystemPrompt]
        }
        if let model = request.model {
            args += ["--model", model]
        }
        if !request.disallowedTools.isEmpty {
            args += ["--disallowedTools"] + request.disallowedTools
        }
        return args
    }

    public func spawn(_ request: SpawnRequest) async throws -> SpawnedAgent {
        let timeout = registrationTimeout
        return try await offMain {
            let launchedAt = Date()
            let result = try ClaudeCLI.run(Self.arguments(for: request), cwd: request.cwd)
            return try Self.registered(from: result, timeout: timeout) { agents in
                ClaudeCLI.recoveredAgent(from: agents, cwd: request.cwd, name: request.name, launchedAt: launchedAt)
            }
        }
    }

    public func resume(sessionId: String, cwd: URL, prompt: String) async throws -> SpawnedAgent {
        let timeout = registrationTimeout
        return try await offMain {
            let result = try ClaudeCLI.run([prompt, "--bg", "--resume", sessionId], cwd: cwd)
            return try Self.registered(from: result, timeout: timeout) { agents in
                agents.first { $0.sessionId == sessionId && $0.id != nil }
            }
        }
    }

    public func stop(shortId: String) async throws {
        try await offMain { try ClaudeCLI.stop(shortId: shortId) }
    }

    public func remove(shortId: String) async throws {
        try await offMain { try ClaudeCLI.remove(shortId: shortId) }
    }

    public func listSessions() async throws -> [AgentInfo] {
        try await offMain { try ClaudeCLI.listAgents() }
    }

    public func attachCommand(shortId: String) -> (executable: String, arguments: [String]) {
        let invocation = ClaudeCLI.invocation()
        return (invocation.executable, invocation.prefix + ["attach", shortId])
    }

    /// A process that exited 0 has a live session whether or not its stdout parsed, so an unparseable
    /// stdout falls back to `claude agents --json` rather than leaving that session orphaned.
    private static func registered(
        from result: CommandResult,
        timeout: TimeInterval,
        recovering select: ([AgentInfo]) -> AgentInfo?
    ) throws -> SpawnedAgent {
        if let shortId = ClaudeCLI.parseShortId(from: result.stdout) {
            guard let sessionId = try ClaudeCLI.waitForAgent(shortId: shortId, timeout: timeout)?.sessionId else {
                throw AgentRuntimeError("claude agents --json never listed short id \(shortId) within \(timeout)s")
            }
            return SpawnedAgent(shortId: shortId, sessionId: sessionId)
        }
        if let recovered = try ClaudeCLI.waitForAgent(timeout: timeout, select: select),
           let shortId = recovered.id, let sessionId = recovered.sessionId {
            return SpawnedAgent(shortId: shortId, sessionId: sessionId)
        }
        throw AgentRuntimeError(
            "claude --bg exited 0 but no short id was found, and no matching session was listed within "
                + "\(timeout)s.\nstdout:\n\(result.stdout)\nstderr:\n\(result.stderr)"
        )
    }

    private func offMain<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try body() }.value
    }
}
