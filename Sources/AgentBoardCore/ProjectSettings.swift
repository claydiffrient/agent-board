import Foundation

public struct Caps: Codable, Sendable, Equatable {
    public var maxConcurrentWorkers: Int = 3
    public var maxTokensPerAgent: Int? = nil
    public var maxWallClockSeconds: Int = 1800
    public var maxIdleSeconds: Int = 300
    public var sessionCeiling: Int? = nil
    /// How long a running worker may go without a hook before the orchestrator sidebar calls it
    /// stalled. Deliberately below `maxIdleSeconds` so a wedge surfaces before the cap kills it.
    public var stallSeconds: Int = 120
    /// How long a worker has to answer a wind-down order before the progress sheet calls it
    /// unacknowledged. Expiry only counts it; killing it stays a human decision.
    public var shutdownGraceSeconds: Int = 120

    public init(
        maxConcurrentWorkers: Int = 3,
        maxTokensPerAgent: Int? = nil,
        maxWallClockSeconds: Int = 1800,
        maxIdleSeconds: Int = 300,
        sessionCeiling: Int? = nil,
        stallSeconds: Int = 120,
        shutdownGraceSeconds: Int = 120
    ) {
        self.maxConcurrentWorkers = maxConcurrentWorkers
        self.maxTokensPerAgent = maxTokensPerAgent
        self.maxWallClockSeconds = maxWallClockSeconds
        self.maxIdleSeconds = maxIdleSeconds
        self.sessionCeiling = sessionCeiling
        self.stallSeconds = stallSeconds
        self.shutdownGraceSeconds = shutdownGraceSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Caps()
        maxConcurrentWorkers = try c.decodeIfPresent(Int.self, forKey: .maxConcurrentWorkers) ?? defaults.maxConcurrentWorkers
        maxTokensPerAgent = try c.decodeIfPresent(Int.self, forKey: .maxTokensPerAgent)
        maxWallClockSeconds = try c.decodeIfPresent(Int.self, forKey: .maxWallClockSeconds) ?? defaults.maxWallClockSeconds
        maxIdleSeconds = try c.decodeIfPresent(Int.self, forKey: .maxIdleSeconds) ?? defaults.maxIdleSeconds
        sessionCeiling = try c.decodeIfPresent(Int.self, forKey: .sessionCeiling)
        stallSeconds = try c.decodeIfPresent(Int.self, forKey: .stallSeconds) ?? defaults.stallSeconds
        shutdownGraceSeconds = try c.decodeIfPresent(Int.self, forKey: .shutdownGraceSeconds) ?? defaults.shutdownGraceSeconds
    }
}

/// When a done task leaves the board. Encoded as `{"mode":...}` with `days` only for `afterDays`.
public enum ArchivePolicy: Codable, Sendable, Equatable {
    case manual
    case afterDays(Int)
    case afterEpicMerge

    enum CodingKeys: String, CodingKey {
        case mode
        case days
    }

    enum Mode: String, Codable {
        case manual
        case afterDays
        case afterEpicMerge
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Mode.self, forKey: .mode) {
        case .manual: self = .manual
        case .afterDays: self = .afterDays(try c.decode(Int.self, forKey: .days))
        case .afterEpicMerge: self = .afterEpicMerge
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .manual:
            try c.encode(Mode.manual, forKey: .mode)
        case .afterDays(let days):
            try c.encode(Mode.afterDays, forKey: .mode)
            try c.encode(days, forKey: .days)
        case .afterEpicMerge:
            try c.encode(Mode.afterEpicMerge, forKey: .mode)
        }
    }
}

public struct ProjectSettings: Codable, Sendable, Equatable {
    public var caps: Caps = Caps()
    public var autonomyEnabled: Bool = false
    public var autoModeJSON: String? = nil
    public var extraMcpServers: [String] = []
    /// Passed as `--model` to every session without its own; nil leaves Claude Code's default.
    public var defaultModel: String? = nil
    /// Free text the orchestrator reads when choosing a model per task.
    public var modelGuidance: String? = nil
    public var archivePolicy: ArchivePolicy = .afterEpicMerge

    public init(
        caps: Caps = Caps(),
        autonomyEnabled: Bool = false,
        autoModeJSON: String? = nil,
        extraMcpServers: [String] = [],
        defaultModel: String? = nil,
        modelGuidance: String? = nil,
        archivePolicy: ArchivePolicy = .afterEpicMerge
    ) {
        self.caps = caps
        self.autonomyEnabled = autonomyEnabled
        self.autoModeJSON = autoModeJSON
        self.extraMcpServers = extraMcpServers
        self.defaultModel = defaultModel
        self.modelGuidance = modelGuidance
        self.archivePolicy = archivePolicy
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        caps = try c.decodeIfPresent(Caps.self, forKey: .caps) ?? Caps()
        autonomyEnabled = try c.decodeIfPresent(Bool.self, forKey: .autonomyEnabled) ?? false
        autoModeJSON = try c.decodeIfPresent(String.self, forKey: .autoModeJSON)
        extraMcpServers = try c.decodeIfPresent([String].self, forKey: .extraMcpServers) ?? []
        defaultModel = try c.decodeIfPresent(String.self, forKey: .defaultModel)
        modelGuidance = try c.decodeIfPresent(String.self, forKey: .modelGuidance)
        archivePolicy = try c.decodeIfPresent(ArchivePolicy.self, forKey: .archivePolicy) ?? .afterEpicMerge
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

extension ProjectSettings {
    /// Second enforcement of D8 (§8), alongside the spawn-time `--disallowedTools` list.
    public static let workerIntegrationDenyRules: [String] = [
        "Worker Push [named+specifics — **must name:** the push and its remote]: Agent Board workers commit and stop — nothing they produce reaches a shared remote unattended. Any push to a remote is blocked: `git push` in every form (including `-u`, `--set-upstream`, `--force`, and pushes of tags or notes), and the same effect reached through another tool or client. The human integrates the branch. Clears only when the user asks for this specific push in this session.",
        "Worker Pull Request Creation [named+specifics — **must name:** the pull request being opened]: Opening a pull request from a worker branch — `gh pr create` (draft included), `git request-pull`, the GitHub or GitLab API, or any other client — publishes the work for review before a human has looked at it. A worker finishes by committing and calling `report_complete`; opening the pull request is the human's call.",
        "Worker Pull Request Merge [named+specifics — **must name:** the pull request being merged]: Merging a pull request — `gh pr merge` in any form (`--auto`, `--admin`, `--squash`, `--rebase`), an API merge, or a merge-button equivalent — integrates work into a shared branch. Integration always requires human approval in Agent Board, autonomy setting regardless.",
    ]

    /// The `$defaults` sentinel expands in place; without it the array replaces Claude Code's shipped rules.
    public static let defaultAutoModeJSON: String = {
        let block = ["soft_deny": ["$defaults"] + workerIntegrationDenyRules]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(block), let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }()

    public static func forNewProject() -> ProjectSettings {
        ProjectSettings(autoModeJSON: defaultAutoModeJSON)
    }
}
