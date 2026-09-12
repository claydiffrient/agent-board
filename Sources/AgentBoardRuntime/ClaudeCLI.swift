import Foundation

public struct AgentInfo: Decodable, Sendable, Equatable {
    public var id: String?
    public var cwd: String
    public var kind: String
    public var sessionId: String?
    public var name: String?
    public var state: String?
    public var status: String?
    public var pid: Int?
    /// Epoch milliseconds, as emitted by `claude agents --json`.
    public var startedAt: Double?

    public var startedDate: Date? {
        startedAt.map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    public init(
        id: String? = nil,
        cwd: String,
        kind: String,
        sessionId: String? = nil,
        name: String? = nil,
        state: String? = nil,
        status: String? = nil,
        pid: Int? = nil,
        startedAt: Double? = nil
    ) {
        self.id = id
        self.cwd = cwd
        self.kind = kind
        self.sessionId = sessionId
        self.name = name
        self.state = state
        self.status = status
        self.pid = pid
        self.startedAt = startedAt
    }
}

public enum ClaudeCLI {
    public static let homebrewPath = "/opt/homebrew/bin/claude"

    public static func invocation() -> (executable: String, prefix: [String]) {
        if FileManager.default.isExecutableFile(atPath: homebrewPath) {
            return (homebrewPath, [])
        }
        return ("/usr/bin/env", ["claude"])
    }

    public static func run(_ args: [String], cwd: URL?) throws -> CommandResult {
        let invocation = invocation()
        return try ProcessRunner.runChecked(
            executable: URL(fileURLWithPath: invocation.executable),
            arguments: invocation.prefix + args,
            cwd: cwd,
            label: "claude"
        )
    }

    public static func listAgents() throws -> [AgentInfo] {
        let result = try run(["agents", "--json", "--all"], cwd: nil)
        guard let data = result.stdout.data(using: .utf8) else {
            throw AgentRuntimeError("claude agents produced non-UTF8 output")
        }
        return try JSONDecoder().decode([AgentInfo].self, from: data)
    }

    public static func stop(shortId: String) throws {
        _ = try run(["stop", shortId], cwd: nil)
    }

    public static func remove(shortId: String) throws {
        _ = try run(["rm", shortId], cwd: nil)
    }

    public static func waitForAgent(shortId: String, timeout: TimeInterval) throws -> AgentInfo? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let match = try listAgents().first(where: { $0.id == shortId }) { return match }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        return nil
    }

    /// Parses `backgrounded · <hex> · <name>`; the name segment is optional.
    public static func parseShortId(from stdout: String) -> String? {
        for line in stdout.split(whereSeparator: \.isNewline) where line.hasPrefix("backgrounded") {
            let fields = line.split(separator: "·").map { $0.trimmingCharacters(in: .whitespaces) }
            if fields.count >= 2, !fields[1].isEmpty, fields[1].allSatisfy(\.isHexDigit) {
                return fields[1]
            }
        }
        return nil
    }
}
