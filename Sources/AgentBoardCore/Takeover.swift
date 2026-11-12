import Foundation
import GRDB

/// `settings_json.takeover` (SPEC §13.8). The trigger labels, acknowledgment label and comment are
/// work-specific and have no defaults; until both labels are set the project cannot be enabled, and
/// decoding treats a stored `enabled` without them as off.
public struct TakeoverSettings: Codable, Sendable, Equatable {
    public var enabled: Bool = false
    /// A `gh` login, or `@me` for whoever `gh` is logged in as.
    public var assignee: String = Self.defaultAssignee
    /// An item is taken over only when it carries every one of these.
    public var triggerLabels: [String] = []
    public var ackLabel: String? = nil
    /// A comment template posted once the acknowledgment label is added.
    public var ackComment: String? = nil
    public var pollMinutes: Int = 5

    public static let defaultAssignee = "@me"

    public init(
        enabled: Bool = false, assignee: String = Self.defaultAssignee, triggerLabels: [String] = [],
        ackLabel: String? = nil, ackComment: String? = nil, pollMinutes: Int = 5
    ) {
        self.enabled = enabled
        self.assignee = assignee
        self.triggerLabels = triggerLabels
        self.ackLabel = ackLabel
        self.ackComment = ackComment
        self.pollMinutes = pollMinutes
    }

    /// Why the project cannot be enabled, or nil once it can. Without trigger labels the search would
    /// match everything assigned to the human.
    public var cannotEnableReason: String? {
        if Self.cleaned(triggerLabels).isEmpty {
            return "Add at least one trigger label. Without one, takeover would claim everything assigned to you."
        }
        if Self.cleaned(ackLabel) == nil {
            return "Set an acknowledgment label. It marks what has been taken over, so the search never claims it twice."
        }
        return nil
    }

    /// Trimmed, blank-free, and turned off when `cannotEnableReason` applies.
    public var normalized: TakeoverSettings {
        var result = self
        result.assignee = Self.cleaned(assignee) ?? Self.defaultAssignee
        result.triggerLabels = Self.cleaned(triggerLabels)
        result.ackLabel = Self.cleaned(ackLabel)
        result.ackComment = Self.cleaned(ackComment)
        result.pollMinutes = max(1, pollMinutes)
        result.enabled = enabled && result.cannotEnableReason == nil
        return result
    }

    static func cleaned(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    static func cleaned(_ labels: [String]) -> [String] {
        var result: [String] = []
        for label in labels.compactMap(cleaned)
        where !result.contains(where: { $0.caseInsensitiveCompare(label) == .orderedSame }) {
            result.append(label)
        }
        return result
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, assignee, triggerLabels, ackLabel, ackComment, pollMinutes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self = TakeoverSettings(
            enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
            assignee: try c.decodeIfPresent(String.self, forKey: .assignee) ?? Self.defaultAssignee,
            triggerLabels: try c.decodeIfPresent([String].self, forKey: .triggerLabels) ?? [],
            ackLabel: try c.decodeIfPresent(String.self, forKey: .ackLabel),
            ackComment: try c.decodeIfPresent(String.self, forKey: .ackComment),
            pollMinutes: try c.decodeIfPresent(Int.self, forKey: .pollMinutes) ?? 5
        ).normalized
    }
}

public enum TakeoverKind: String, Codable, Sendable, CaseIterable, Equatable, DatabaseValueConvertible {
    case issue
    case pr
}

/// Where a taken-over item is (SPEC §13.8). `done`, `released` and `failed` are terminal.
public enum TakeoverState: String, Codable, Sendable, CaseIterable, Equatable, DatabaseValueConvertible {
    case found
    case acknowledged
    case working
    case watched
    case done
    case released
    case failed

    public var isTerminal: Bool { self == .done || self == .released || self == .failed }

    /// The forward edges; `released` and `failed` are reachable from every non-terminal state.
    public func canMove(to next: TakeoverState) -> Bool {
        guard !isTerminal else { return false }
        switch next {
        case .released, .failed: return true
        case .acknowledged: return self == .found
        case .working: return self == .acknowledged
        case .watched: return self == .acknowledged || self == .working
        case .done: return self == .watched
        case .found: return false
        }
    }
}

public struct Takeover: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
    public static let databaseTableName = "takeover"

    public var id: String
    public var projectId: String
    public var githubNodeId: String
    public var kind: TakeoverKind
    public var number: Int
    public var url: String
    /// The issue a found pull request closes, when both were found together (SPEC §13.8).
    public var issueNodeId: String?
    public var issueURL: String?
    public var title: String
    public var author: String?
    public var isCrossRepository: Bool
    public var state: TakeoverState
    public var taskId: String?
    public var watchId: String?
    public var failure: String?
    public var createdAt: Int64
    public var updatedAt: Int64

    public enum CodingKeys: String, CodingKey {
        case id
        case projectId = "project_id"
        case githubNodeId = "github_node_id"
        case kind
        case number
        case url
        case issueNodeId = "issue_node_id"
        case issueURL = "issue_url"
        case title
        case author
        case isCrossRepository = "is_cross_repository"
        case state
        case taskId = "task_id"
        case watchId = "watch_id"
        case failure
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public static func newId() -> String { BoardId.new() }
}

/// One open issue or pull request the discovery search found, before it is recorded.
public struct TakeoverCandidate: Sendable, Equatable {
    public var githubNodeId: String
    public var kind: TakeoverKind
    public var number: Int
    public var url: String
    public var title: String
    public var author: String?
    public var isCrossRepository: Bool
    public var issueNodeId: String?
    public var issueURL: String?

    public init(
        githubNodeId: String, kind: TakeoverKind, number: Int, url: String, title: String, author: String?,
        isCrossRepository: Bool = false, issueNodeId: String? = nil, issueURL: String? = nil
    ) {
        self.githubNodeId = githubNodeId
        self.kind = kind
        self.number = number
        self.url = url
        self.title = title
        self.author = author
        self.isCrossRepository = isCrossRepository
        self.issueNodeId = issueNodeId
        self.issueURL = issueURL
    }
}
