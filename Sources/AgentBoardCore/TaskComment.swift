import Foundation
import GRDB

public enum CommentAuthorKind: String, Codable, Sendable, CaseIterable, Equatable, DatabaseValueConvertible {
    case human
    case orchestrator
    case worker
    case reviewer
}

/// Who wrote a comment. `name` is a snapshot taken when the comment is written, so the comment
/// still names a rostered agent after the agent is deleted and `rosterAgentId` is nulled (SPEC §4).
public struct CommentAuthor: Sendable, Equatable {
    public var kind: CommentAuthorKind
    public var sessionId: String?
    public var rosterAgentId: String?
    public var name: String

    public init(kind: CommentAuthorKind, sessionId: String? = nil, rosterAgentId: String? = nil, name: String) {
        self.kind = kind
        self.sessionId = sessionId
        self.rosterAgentId = rosterAgentId
        self.name = name
    }

    /// Stored as `human`; the UI shows "You".
    public static let human = CommentAuthor(kind: .human, name: TaskComment.humanAuthorName)
}

public enum CommentError: Error, Equatable, Sendable {
    case emptyBody
    case bodyTooLong(limit: Int)
}

public struct TaskComment: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Sendable, Equatable {
    public static let databaseTableName = "task_comment"

    public static let humanAuthorName = "human"

    /// Counted in Unicode scalars, which is what SQLite's `length()` counts in the column's CHECK.
    public static let maxBodyLength = 10_000

    public var id: Int64?
    public var taskId: String
    public var projectId: String
    public var authorKind: CommentAuthorKind
    public var authorSessionId: String?
    public var authorRosterAgentId: String?
    public var authorName: String
    public var body: String
    public var createdAt: Int64

    public enum CodingKeys: String, CodingKey {
        case id
        case taskId = "task_id"
        case projectId = "project_id"
        case authorKind = "author_kind"
        case authorSessionId = "author_session_id"
        case authorRosterAgentId = "author_roster_agent_id"
        case authorName = "author_name"
        case body
        case createdAt = "created_at"
    }

    public init(
        id: Int64? = nil, taskId: String, projectId: String, author: CommentAuthor, body: String, createdAt: Int64
    ) {
        self.id = id
        self.taskId = taskId
        self.projectId = projectId
        self.authorKind = author.kind
        self.authorSessionId = author.sessionId
        self.authorRosterAgentId = author.rosterAgentId
        self.authorName = author.name
        self.body = body
        self.createdAt = createdAt
    }

    public var author: CommentAuthor {
        CommentAuthor(kind: authorKind, sessionId: authorSessionId, rosterAgentId: authorRosterAgentId, name: authorName)
    }

    public var createdDate: Date { createdAt.asDate }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension Board {
    /// Refuses a missing task and another project's task with the same error, so a caller cannot
    /// tell the two apart and probe ids across the project boundary.
    @discardableResult
    public func addComment(projectId: String, taskId: String, author: CommentAuthor, body: String) throws -> TaskComment {
        let text = try CommentStore.validated(body)
        return try db.writer.write { db in
            guard let task = try Task.fetchOne(db, key: taskId), task.projectId == projectId else {
                throw BoardError.taskNotFound(taskId)
            }
            return try CommentStore.insert(db, task: task, author: author, body: text)
        }
    }
}

/// A task's comments, oldest first, with what the inspector needs to name their authors.
public struct CommentThread: Sendable, Equatable {
    public var comments: [TaskComment]
    /// Current roster names by roster agent id; a deleted agent is absent.
    public var rosterNames: [String: String]
    /// Session short ids by session id, for the sessions that have one.
    public var shortIds: [String: String]

    public init(comments: [TaskComment] = [], rosterNames: [String: String] = [:], shortIds: [String: String] = [:]) {
        self.comments = comments
        self.rosterNames = rosterNames
        self.shortIds = shortIds
    }

    /// `You`, `Orchestrator`, `Rita · reviewer`, or `Worker 3f9a1c2e` (SPEC §10). With no roster
    /// agent, a snapshot that is more than the role word names an agent since deleted from the roster.
    public func authorLabel(_ comment: TaskComment) -> String {
        let role = comment.authorKind.rawValue
        switch comment.authorKind {
        case .human:
            return "You"
        case .orchestrator:
            return "Orchestrator"
        case .worker, .reviewer:
            if let id = comment.authorRosterAgentId, let name = rosterNames[id] {
                return "\(name) · \(role)"
            }
            let snapshot = comment.authorName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !snapshot.isEmpty, snapshot.lowercased() != role {
                return "\(snapshot) · \(role)"
            }
            guard let sessionId = comment.authorSessionId else { return role.capitalized }
            return "\(role.capitalized) \(shortIds[sessionId] ?? String(sessionId.prefix(8)))"
        }
    }
}
