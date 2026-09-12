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
        try waitForAgent(timeout: timeout) { agents in agents.first { $0.id == shortId } }
    }

    public static func waitForAgent(
        timeout: TimeInterval,
        select: ([AgentInfo]) -> AgentInfo?
    ) throws -> AgentInfo? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let match = select(try listAgents()) { return match }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        return nil
    }

    /// The background session a spawn in `cwd` under `name` created, for when its stdout could not be
    /// parsed. Every field must agree, so a concurrent spawn elsewhere is never adopted by mistake.
    public static func recoveredAgent(
        from agents: [AgentInfo],
        cwd: URL,
        name: String,
        launchedAt: Date
    ) -> AgentInfo? {
        let wanted = canonicalPath(cwd)
        // `startedAt` comes from the child's own clock, so allow a second of skew against ours.
        let floor = launchedAt.addingTimeInterval(-1)
        return agents
            .filter { agent in
                agent.id != nil && agent.sessionId != nil
                    && agent.kind == "background"
                    && agent.name == name
                    && canonicalPath(URL(fileURLWithPath: agent.cwd)) == wanted
                    && (agent.startedDate ?? .distantPast) >= floor
            }
            .max { ($0.startedAt ?? 0) < ($1.startedAt ?? 0) }
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Parses `backgrounded · <hex> · <name>`; the name segment is optional.
    public static func parseShortId(from stdout: String) -> String? {
        for rawLine in strippingANSIEscapes(stdout).split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("backgrounded") else { continue }
            let fields = line.split(separator: "·").map { $0.trimmingCharacters(in: .whitespaces) }
            if fields.count >= 2, !fields[1].isEmpty, fields[1].allSatisfy(\.isHexDigit) {
                return fields[1]
            }
        }
        return nil
    }

    /// Removes CSI sequences (colour, cursor moves) and the string sequences (OSC, DCS, APC, PM, SOS)
    /// a colour-forcing environment writes into a piped stdout.
    public static func strippingANSIEscapes(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        var output = ""
        output.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == "\u{1B}" else {
                output.append(character)
                index = text.index(after: index)
                continue
            }
            index = text.index(after: index)
            guard index < text.endIndex else { break }
            let introducer = text[index]
            index = text.index(after: index)
            switch introducer {
            case "[":
                while index < text.endIndex, !("@"..."~").contains(text[index]) {
                    index = text.index(after: index)
                }
                if index < text.endIndex { index = text.index(after: index) }
            case "]", "P", "X", "^", "_":
                while index < text.endIndex {
                    if text[index] == "\u{07}" {
                        index = text.index(after: index)
                        break
                    }
                    let next = text.index(after: index)
                    if text[index] == "\u{1B}", next < text.endIndex, text[next] == "\\" {
                        index = text.index(after: next)
                        break
                    }
                    index = text.index(after: index)
                }
            default:
                break
            }
        }
        return output
    }
}
