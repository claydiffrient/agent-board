import Foundation

struct SpawnPlan {
    var port: Int
    var token: String
    var cwd: URL
    var name: String
    var configId: UUID
    var prompt: String
    var configDir: URL
}

struct SpawnedSession {
    var shortId: String
    var sessionId: String
    var settingsPath: URL
    var mcpConfigPath: URL
}

struct AgentInfo: Decodable {
    var id: String?
    var cwd: String
    var kind: String
    var sessionId: String?
    var name: String?
    var state: String?
    var status: String?
    var pid: Int?
}

struct SpawnerError: Error, CustomStringConvertible {
    var description: String
}

enum Spawner {
    static let hookEvents = ["SessionStart", "PostToolUse", "Notification", "Stop", "SessionEnd"]

    static func writeConfigs(_ plan: SpawnPlan) throws -> (settings: URL, mcpConfig: URL) {
        try FileManager.default.createDirectory(at: plan.configDir, withIntermediateDirectories: true)

        let url = "http://127.0.0.1:\(plan.port)/hooks?token=\(plan.token)"
        let httpHook: [String: Any] = ["type": "http", "url": url, "timeout": 5]
        let curlHook: [String: Any] = [
            "type": "command",
            "command": "curl -s -m 5 -X POST -H 'Content-Type: application/json' --data-binary @- '\(url)' >/dev/null",
        ]
        var hooks: [String: Any] = [:]
        for event in hookEvents {
            hooks[event] = [["hooks": [event == "SessionStart" ? curlHook : httpHook]]]
        }
        let settings: [String: Any] = ["hooks": hooks]

        let mcpConfig: [String: Any] = [
            "mcpServers": [
                "agent-board": [
                    "type": "http",
                    "url": "http://127.0.0.1:\(plan.port)/mcp",
                    "headers": ["Authorization": "Bearer \(plan.token)"],
                ],
            ],
        ]

        let id = plan.configId.uuidString.lowercased()
        let settingsURL = plan.configDir.appendingPathComponent("settings-\(id).json")
        let mcpURL = plan.configDir.appendingPathComponent("mcp-\(id).json")
        try writeJSON(settings, to: settingsURL)
        try writeJSON(mcpConfig, to: mcpURL)
        return (settingsURL, mcpURL)
    }

    static func spawnBackground(_ plan: SpawnPlan) throws -> SpawnedSession {
        let configs = try writeConfigs(plan)
        let args = [
            plan.prompt,
            "--bg",
            "-n", plan.name,
            "--permission-mode", "auto",
            "--strict-mcp-config",
            "--mcp-config", configs.mcpConfig.path,
            "--settings", configs.settings.path,
            "--disallowedTools", "Bash(git push*)", "Bash(gh pr create*)", "Bash(gh pr merge*)",
        ]
        let result = try runClaude(args, cwd: plan.cwd)

        guard let shortId = parseShortId(from: result.stdout) else {
            throw SpawnerError(description: "claude --bg exited 0 but no short id was found.\nstdout:\n\(result.stdout)\nstderr:\n\(result.stderr)")
        }
        guard let sessionId = try waitForAgent(shortId: shortId, timeout: 10)?.sessionId else {
            throw SpawnerError(description: "claude agents --json never listed short id \(shortId)")
        }
        return SpawnedSession(shortId: shortId, sessionId: sessionId, settingsPath: configs.settings, mcpConfigPath: configs.mcpConfig)
    }

    static func listAgents() throws -> [AgentInfo] {
        let result = try runClaude(["agents", "--json", "--all"], cwd: nil)
        guard let data = result.stdout.data(using: .utf8) else {
            throw SpawnerError(description: "claude agents produced non-UTF8 output")
        }
        return try JSONDecoder().decode([AgentInfo].self, from: data)
    }

    static func stop(shortId: String) throws {
        _ = try runClaude(["stop", shortId], cwd: nil)
    }

    static func remove(shortId: String) throws {
        _ = try runClaude(["rm", shortId], cwd: nil)
    }

    static func waitForAgent(shortId: String, timeout: Double) throws -> AgentInfo? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let match = try listAgents().first(where: { $0.id == shortId }) { return match }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return nil
    }

    static func parseShortId(from stdout: String) -> String? {
        for line in stdout.split(whereSeparator: \.isNewline) where line.hasPrefix("backgrounded") {
            let fields = line.split(separator: "·").map { $0.trimmingCharacters(in: .whitespaces) }
            if fields.count >= 2, !fields[1].isEmpty, fields[1].allSatisfy(\.isHexDigit) { return fields[1] }
        }
        return nil
    }

    private struct CommandResult {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    private static func claudeInvocation() -> (executable: URL, prefix: [String]) {
        let brew = URL(fileURLWithPath: "/opt/homebrew/bin/claude")
        if FileManager.default.isExecutableFile(atPath: brew.path) {
            return (brew, [])
        }
        return (URL(fileURLWithPath: "/usr/bin/env"), ["claude"])
    }

    private static func runClaude(_ args: [String], cwd: URL?) throws -> CommandResult {
        let invocation = claudeInvocation()
        let process = Process()
        process.executableURL = invocation.executable
        process.arguments = invocation.prefix + args
        process.currentDirectoryURL = cwd
        process.environment = ProcessInfo.processInfo.environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        try process.run()
        var stderrData = Data()
        let stderrDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            stderrDone.signal()
        }
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        stderrDone.wait()
        process.waitUntilExit()

        let result = CommandResult(
            status: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self)
        )
        guard result.status == 0 else {
            throw SpawnerError(description: "claude \(args.joined(separator: " ")) exited \(result.status)\nstdout:\n\(result.stdout)\nstderr:\n\(result.stderr)")
        }
        return result
    }

    private static func writeJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }
}
