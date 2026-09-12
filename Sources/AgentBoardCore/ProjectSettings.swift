import Foundation

public struct Caps: Codable, Sendable, Equatable {
    public var maxConcurrentWorkers: Int = 3
    public var maxTokensPerAgent: Int = 150_000
    public var maxWallClockSeconds: Int = 1800
    public var maxIdleSeconds: Int = 300
    public var sessionCeiling: Int? = nil

    public init(
        maxConcurrentWorkers: Int = 3,
        maxTokensPerAgent: Int = 150_000,
        maxWallClockSeconds: Int = 1800,
        maxIdleSeconds: Int = 300,
        sessionCeiling: Int? = nil
    ) {
        self.maxConcurrentWorkers = maxConcurrentWorkers
        self.maxTokensPerAgent = maxTokensPerAgent
        self.maxWallClockSeconds = maxWallClockSeconds
        self.maxIdleSeconds = maxIdleSeconds
        self.sessionCeiling = sessionCeiling
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Caps()
        maxConcurrentWorkers = try c.decodeIfPresent(Int.self, forKey: .maxConcurrentWorkers) ?? defaults.maxConcurrentWorkers
        maxTokensPerAgent = try c.decodeIfPresent(Int.self, forKey: .maxTokensPerAgent) ?? defaults.maxTokensPerAgent
        maxWallClockSeconds = try c.decodeIfPresent(Int.self, forKey: .maxWallClockSeconds) ?? defaults.maxWallClockSeconds
        maxIdleSeconds = try c.decodeIfPresent(Int.self, forKey: .maxIdleSeconds) ?? defaults.maxIdleSeconds
        sessionCeiling = try c.decodeIfPresent(Int.self, forKey: .sessionCeiling)
    }
}

public struct ProjectSettings: Codable, Sendable, Equatable {
    public var caps: Caps = Caps()
    public var autonomyEnabled: Bool = false
    public var autoModeJSON: String? = nil
    public var extraMcpServers: [String] = []

    public init(
        caps: Caps = Caps(),
        autonomyEnabled: Bool = false,
        autoModeJSON: String? = nil,
        extraMcpServers: [String] = []
    ) {
        self.caps = caps
        self.autonomyEnabled = autonomyEnabled
        self.autoModeJSON = autoModeJSON
        self.extraMcpServers = extraMcpServers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        caps = try c.decodeIfPresent(Caps.self, forKey: .caps) ?? Caps()
        autonomyEnabled = try c.decodeIfPresent(Bool.self, forKey: .autonomyEnabled) ?? false
        autoModeJSON = try c.decodeIfPresent(String.self, forKey: .autoModeJSON)
        extraMcpServers = try c.decodeIfPresent([String].self, forKey: .extraMcpServers) ?? []
    }

    public static func decode(_ json: String) -> ProjectSettings {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ProjectSettings.self, from: data)
        else { return ProjectSettings() }
        return decoded
    }

    public func encoded() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self), let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}
