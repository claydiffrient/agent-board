import Foundation
import GRDB

public struct Project: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
    public static let databaseTableName = "project"

    public var id: String
    public var name: String
    public var repoPath: String
    public var baseBranch: String
    public var worktreeRoot: String
    public var memoryDir: String?
    public var orchSessionId: String?
    public var settingsJSON: String
    public var createdAt: Int64

    public enum CodingKeys: String, CodingKey {
        case id
        case name
        case repoPath = "repo_path"
        case baseBranch = "base_branch"
        case worktreeRoot = "worktree_root"
        case memoryDir = "memory_dir"
        case orchSessionId = "orch_session_id"
        case settingsJSON = "settings_json"
        case createdAt = "created_at"
    }

    public init(
        id: String, name: String, repoPath: String, baseBranch: String, worktreeRoot: String,
        memoryDir: String?, orchSessionId: String?, settingsJSON: String, createdAt: Int64
    ) {
        self.id = id
        self.name = name
        self.repoPath = repoPath
        self.baseBranch = baseBranch
        self.worktreeRoot = worktreeRoot
        self.memoryDir = memoryDir
        self.orchSessionId = orchSessionId
        self.settingsJSON = settingsJSON
        self.createdAt = createdAt
    }

    public static func newId() -> String { BoardId.new() }

    public var createdDate: Date { createdAt.asDate }

    public var settings: ProjectSettings {
        get { ProjectSettings.decode(settingsJSON) }
        set { settingsJSON = newValue.encoded() }
    }
}

public struct Epic: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
    public static let databaseTableName = "epic"

    public var id: String
    public var projectId: String
    public var title: String
    public var goal: String?
    public var branch: String
    public var state: EpicState
    public var createdAt: Int64

    public enum CodingKeys: String, CodingKey {
        case id
        case projectId = "project_id"
        case title
        case goal
        case branch
        case state
        case createdAt = "created_at"
    }

    public init(id: String, projectId: String, title: String, goal: String?, branch: String, state: EpicState, createdAt: Int64) {
        self.id = id
        self.projectId = projectId
        self.title = title
        self.goal = goal
        self.branch = branch
        self.state = state
        self.createdAt = createdAt
    }

    public static func newId() -> String { BoardId.new() }

    public var createdDate: Date { createdAt.asDate }
}

public struct Task: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
    public static let databaseTableName = "task"

    public var id: String
    public var projectId: String
    public var epicId: String?
    public var title: String
    public var body: String?
    public var acceptance: String?
    public var priority: String?
    public var column: TaskColumn
    public var blocked: Bool
    public var blockedReason: String?
    public var failed: Bool
    public var failureReason: String?
    public var ordering: Double
    public var origin: TaskOrigin
    public var createdAt: Int64
    public var updatedAt: Int64
    /// Overrides the project's default model for the worker on this task.
    public var model: String?

    public enum CodingKeys: String, CodingKey {
        case id
        case projectId = "project_id"
        case epicId = "epic_id"
        case title
        case body
        case acceptance
        case priority
        case column = "column_name"
        case blocked
        case blockedReason = "blocked_reason"
        case failed
        case failureReason = "failure_reason"
        case ordering
        case origin
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case model
    }

    public init(
        id: String, projectId: String, epicId: String?, title: String, body: String?, acceptance: String?,
        priority: String?, column: TaskColumn, blocked: Bool = false, blockedReason: String? = nil,
        failed: Bool = false, failureReason: String? = nil, ordering: Double, origin: TaskOrigin,
        createdAt: Int64, updatedAt: Int64, model: String? = nil
    ) {
        self.model = model
        self.id = id
        self.projectId = projectId
        self.epicId = epicId
        self.title = title
        self.body = body
        self.acceptance = acceptance
        self.priority = priority
        self.column = column
        self.blocked = blocked
        self.blockedReason = blockedReason
        self.failed = failed
        self.failureReason = failureReason
        self.ordering = ordering
        self.origin = origin
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static func newId() -> String { BoardId.new() }

    public var createdDate: Date { createdAt.asDate }
    public var updatedDate: Date { updatedAt.asDate }
}

public typealias BoardTask = Task

public struct TaskDep: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "task_dep"

    public var taskId: String
    public var dependsOn: String

    public enum CodingKeys: String, CodingKey {
        case taskId = "task_id"
        case dependsOn = "depends_on"
    }

    public init(taskId: String, dependsOn: String) {
        self.taskId = taskId
        self.dependsOn = dependsOn
    }
}

public struct AgentSession: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
    public static let databaseTableName = "agent_session"

    public var sessionId: String
    public var shortId: String?
    public var projectId: String
    public var taskId: String?
    public var role: SessionRole
    public var worktreePath: String?
    public var branch: String?
    public var cwd: String
    public var state: SessionState
    public var startedAt: Int64
    public var endedAt: Int64?
    public var lastActivity: Int64?
    public var transcriptPath: String?
    public var tokensIn: Int
    public var tokensOut: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    public var estCostUSD: Double
    public var attempt: Int
    public var model: String?
    public var lastTool: String?
    public var stopReason: String?

    public enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case shortId = "short_id"
        case projectId = "project_id"
        case taskId = "task_id"
        case role
        case worktreePath = "worktree_path"
        case branch
        case cwd
        case state
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case lastActivity = "last_activity"
        case transcriptPath = "transcript_path"
        case tokensIn = "tokens_in"
        case tokensOut = "tokens_out"
        case cacheRead = "cache_read"
        case cacheWrite = "cache_write"
        case estCostUSD = "est_cost_usd"
        case attempt
        case model
        case lastTool = "last_tool"
        case stopReason = "stop_reason"
    }

    public init(
        sessionId: String, shortId: String? = nil, projectId: String, taskId: String? = nil, role: SessionRole,
        worktreePath: String? = nil, branch: String? = nil, cwd: String, state: SessionState = .starting,
        startedAt: Int64 = .nowMillis, endedAt: Int64? = nil, lastActivity: Int64? = nil,
        transcriptPath: String? = nil, tokensIn: Int = 0, tokensOut: Int = 0, cacheRead: Int = 0,
        cacheWrite: Int = 0, estCostUSD: Double = 0, attempt: Int = 1, model: String? = nil,
        lastTool: String? = nil, stopReason: String? = nil
    ) {
        self.sessionId = sessionId
        self.shortId = shortId
        self.projectId = projectId
        self.taskId = taskId
        self.role = role
        self.worktreePath = worktreePath
        self.branch = branch
        self.cwd = cwd
        self.state = state
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.lastActivity = lastActivity
        self.transcriptPath = transcriptPath
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.estCostUSD = estCostUSD
        self.attempt = attempt
        self.model = model
        self.lastTool = lastTool
        self.stopReason = stopReason
    }

    public var id: String { sessionId }
    public var startedDate: Date { startedAt.asDate }
    public var endedDate: Date? { endedAt?.asDate }
    public var lastActivityDate: Date? { lastActivity?.asDate }
    public var totalTokens: Int { tokensIn + tokensOut + cacheRead + cacheWrite }
    /// What the token cap meters: uncached input plus output (see CapEvaluator).
    public var countedTokens: Int { tokensIn + tokensOut }
}

public struct TokenGrant: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
    public static let databaseTableName = "token_grant"

    public var token: String
    public var sessionId: String?
    public var projectId: String
    public var scope: TokenScope
    public var taskId: String?
    public var createdAt: Int64
    public var revokedAt: Int64?

    public enum CodingKeys: String, CodingKey {
        case token
        case sessionId = "session_id"
        case projectId = "project_id"
        case scope
        case taskId = "task_id"
        case createdAt = "created_at"
        case revokedAt = "revoked_at"
    }

    public init(token: String, sessionId: String?, projectId: String, scope: TokenScope, taskId: String?, createdAt: Int64, revokedAt: Int64? = nil) {
        self.token = token
        self.sessionId = sessionId
        self.projectId = projectId
        self.scope = scope
        self.taskId = taskId
        self.createdAt = createdAt
        self.revokedAt = revokedAt
    }

    public var id: String { token }
    public var isRevoked: Bool { revokedAt != nil }
}

public struct ProgressEntry: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Sendable, Equatable {
    public static let databaseTableName = "progress"

    public var id: Int64?
    public var taskId: String
    public var sessionId: String?
    public var at: Int64
    public var kind: ProgressKind
    public var text: String

    public enum CodingKeys: String, CodingKey {
        case id
        case taskId = "task_id"
        case sessionId = "session_id"
        case at
        case kind
        case text
    }

    public init(id: Int64? = nil, taskId: String, sessionId: String?, at: Int64, kind: ProgressKind, text: String) {
        self.id = id
        self.taskId = taskId
        self.sessionId = sessionId
        self.at = at
        self.kind = kind
        self.text = text
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public var date: Date { at.asDate }
}

public struct Report: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Sendable, Equatable {
    public static let databaseTableName = "report"

    public var id: Int64?
    public var projectId: String
    public var taskId: String?
    public var sessionId: String?
    public var kind: ReportKind
    public var body: String
    public var createdAt: Int64
    public var consumedAt: Int64?

    public enum CodingKeys: String, CodingKey {
        case id
        case projectId = "project_id"
        case taskId = "task_id"
        case sessionId = "session_id"
        case kind
        case body
        case createdAt = "created_at"
        case consumedAt = "consumed_at"
    }

    public init(id: Int64? = nil, projectId: String, taskId: String?, sessionId: String?, kind: ReportKind, body: String, createdAt: Int64, consumedAt: Int64? = nil) {
        self.id = id
        self.projectId = projectId
        self.taskId = taskId
        self.sessionId = sessionId
        self.kind = kind
        self.body = body
        self.createdAt = createdAt
        self.consumedAt = consumedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public var createdDate: Date { createdAt.asDate }
    public var isConsumed: Bool { consumedAt != nil }
}

public struct Approval: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
    public static let databaseTableName = "approval"

    public var id: String
    public var projectId: String
    public var kind: ApprovalKind
    public var taskId: String?
    public var epicId: String?
    public var requestedBy: String
    public var reason: String?
    public var createdAt: Int64
    public var resolvedAt: Int64?
    public var resolution: ApprovalResolution?

    public enum CodingKeys: String, CodingKey {
        case id
        case projectId = "project_id"
        case kind
        case taskId = "task_id"
        case epicId = "epic_id"
        case requestedBy = "requested_by"
        case reason
        case createdAt = "created_at"
        case resolvedAt = "resolved_at"
        case resolution
    }

    public init(
        id: String, projectId: String, kind: ApprovalKind, taskId: String?, epicId: String?,
        requestedBy: String, reason: String?, createdAt: Int64, resolvedAt: Int64? = nil,
        resolution: ApprovalResolution? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.kind = kind
        self.taskId = taskId
        self.epicId = epicId
        self.requestedBy = requestedBy
        self.reason = reason
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
        self.resolution = resolution
    }

    public static func newId() -> String { BoardId.new() }

    public var isPending: Bool { resolvedAt == nil }
    public var createdDate: Date { createdAt.asDate }
    public var resolvedDate: Date? { resolvedAt?.asDate }
}

public struct Note: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
    public static let databaseTableName = "note"

    public var id: String
    public var projectId: String
    public var title: String
    public var pinned: Bool
    public var version: Int64
    public var updatedAt: Int64

    public enum CodingKeys: String, CodingKey {
        case id
        case projectId = "project_id"
        case title
        case pinned
        case version
        case updatedAt = "updated_at"
    }

    public init(id: String, projectId: String, title: String, pinned: Bool = false, version: Int64 = 1, updatedAt: Int64) {
        self.id = id
        self.projectId = projectId
        self.title = title
        self.pinned = pinned
        self.version = version
        self.updatedAt = updatedAt
    }

    public static func newId() -> String { BoardId.new() }

    public var updatedDate: Date { updatedAt.asDate }
}

public struct NoteSection: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "note_section"

    public var noteId: String
    public var heading: String
    public var body: String
    public var ordering: Double
    /// Session id of the agent that last wrote this section; nil when a human wrote it in the app.
    public var writtenBy: String?

    public enum CodingKeys: String, CodingKey {
        case noteId = "note_id"
        case heading
        case body
        case ordering
        case writtenBy = "written_by"
    }

    public init(noteId: String, heading: String, body: String, ordering: Double, writtenBy: String? = nil) {
        self.noteId = noteId
        self.heading = heading
        self.body = body
        self.ordering = ordering
        self.writtenBy = writtenBy
    }
}

public struct NoteLink: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "note_link"

    public var noteId: String
    public var taskId: String?
    public var epicId: String?

    public enum CodingKeys: String, CodingKey {
        case noteId = "note_id"
        case taskId = "task_id"
        case epicId = "epic_id"
    }

    public init(noteId: String, taskId: String?, epicId: String?) {
        self.noteId = noteId
        self.taskId = taskId
        self.epicId = epicId
    }
}

public struct HookEventRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Sendable, Equatable {
    public static let databaseTableName = "hook_event"

    public var id: Int64?
    public var sessionId: String?
    public var event: String
    public var payload: String
    public var at: Int64

    public enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case event
        case payload
        case at
    }

    public init(id: Int64? = nil, sessionId: String?, event: String, payload: String, at: Int64) {
        self.id = id
        self.sessionId = sessionId
        self.event = event
        self.payload = payload
        self.at = at
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public var date: Date { at.asDate }
}

/// A specialist that outlives any one task. Not owned by a project — projects opt in
/// through `project_roster_agent`.
public struct RosterAgent: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
    public static let databaseTableName = "roster_agent"

    public var id: String
    public var name: String
    /// Free-text specialty the handoff matches against ("frontend", "reviewer"). Deliberately
    /// not an enum: the roster is user-defined, so a new role must not need a migration.
    public var role: String
    /// Injected at spawn as the agent's identity and specialty.
    public var systemPrompt: String
    /// Overrides the project's default model for this agent's sessions.
    public var model: String?
    /// Tools this agent may use; empty inherits whatever the project grants a worker.
    public var toolScope: [String]
    public var enabled: Bool
    public var createdAt: Int64
    public var updatedAt: Int64

    public enum CodingKeys: String, CodingKey {
        case id
        case name
        case role
        case systemPrompt = "system_prompt"
        case model
        case toolScope = "tool_scope"
        case enabled
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(
        id: String, name: String, role: String, systemPrompt: String, model: String? = nil,
        toolScope: [String] = [], enabled: Bool = true, createdAt: Int64, updatedAt: Int64
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.systemPrompt = systemPrompt
        self.model = model
        self.toolScope = toolScope
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static func newId() -> String { BoardId.new() }

    public var createdDate: Date { createdAt.asDate }
    public var updatedDate: Date { updatedAt.asDate }
}

public struct ProjectRosterAgent: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "project_roster_agent"

    public var projectId: String
    public var rosterAgentId: String
    public var ordering: Double

    public enum CodingKeys: String, CodingKey {
        case projectId = "project_id"
        case rosterAgentId = "roster_agent_id"
        case ordering
    }

    public init(projectId: String, rosterAgentId: String, ordering: Double) {
        self.projectId = projectId
        self.rosterAgentId = rosterAgentId
        self.ordering = ordering
    }
}
