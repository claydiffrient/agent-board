import Foundation
import GRDB

/// A task's comment thread. Append-only: nothing edits or deletes a comment, and a comment goes
/// only when its task does, through the foreign key's cascade (SPEC §4).
public struct CommentStore: Sendable {
    let db: AppDatabase

    public init(_ db: AppDatabase) {
        self.db = db
    }

    @discardableResult
    public func add(taskId: String, author: CommentAuthor, body: String) throws -> TaskComment {
        let text = try Self.validated(body)
        return try db.writer.write { db in
            guard let task = try Task.fetchOne(db, key: taskId) else {
                throw BoardError.taskNotFound(taskId)
            }
            return try Self.insert(db, task: task, author: author, body: text)
        }
    }

    static func validated(_ body: String) throws -> String {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CommentError.emptyBody }
        guard text.unicodeScalars.count <= TaskComment.maxBodyLength else {
            throw CommentError.bodyTooLong(limit: TaskComment.maxBodyLength)
        }
        return text
    }

    static func insert(_ db: Database, task: Task, author: CommentAuthor, body: String) throws -> TaskComment {
        var comment = TaskComment(
            taskId: task.id, projectId: task.projectId, author: author, body: body, createdAt: .nowMillis
        )
        try comment.insert(db)
        return comment
    }

    /// Oldest first.
    public func list(taskId: String) throws -> [TaskComment] {
        try db.reader.read { db in try Self.list(db, taskId: taskId) }
    }

    static func list(_ db: Database, taskId: String) throws -> [TaskComment] {
        try TaskComment.fetchAll(
            db,
            sql: "SELECT * FROM task_comment WHERE task_id = ? ORDER BY created_at, id",
            arguments: [taskId]
        )
    }

    public func observe(taskId: String) -> ValueObservation<ValueReducers.Fetch<[TaskComment]>> {
        ValueObservation.tracking { db in try Self.list(db, taskId: taskId) }
    }

    public func thread(taskId: String) throws -> CommentThread {
        try db.reader.read { db in try Self.thread(db, taskId: taskId) }
    }

    public func observeThread(taskId: String) -> ValueObservation<ValueReducers.Fetch<CommentThread>> {
        ValueObservation.tracking { db in try Self.thread(db, taskId: taskId) }
    }

    static func thread(_ db: Database, taskId: String) throws -> CommentThread {
        let comments = try list(db, taskId: taskId)
        let rosterIds = Array(Set(comments.compactMap(\.authorRosterAgentId)))
        let sessionIds = Array(Set(comments.compactMap(\.authorSessionId)))
        var thread = CommentThread(comments: comments)
        if !rosterIds.isEmpty {
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, name FROM roster_agent WHERE id IN (\(databaseQuestionMarks(count: rosterIds.count)))",
                arguments: StatementArguments(rosterIds)
            )
            thread.rosterNames = Dictionary(uniqueKeysWithValues: rows.map { ($0["id"], $0["name"]) })
        }
        if !sessionIds.isEmpty {
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT session_id, short_id FROM agent_session
                    WHERE short_id IS NOT NULL AND session_id IN (\(databaseQuestionMarks(count: sessionIds.count)))
                    """,
                arguments: StatementArguments(sessionIds)
            )
            thread.shortIds = Dictionary(uniqueKeysWithValues: rows.map { ($0["session_id"], $0["short_id"]) })
        }
        return thread
    }

    /// Comment count per task in the project, for the card badge. A task with no comments is absent.
    public func counts(projectId: String) throws -> [String: Int] {
        try db.reader.read { db in try Self.counts(db, projectId: projectId) }
    }

    public func observeCounts(projectId: String) -> ValueObservation<ValueReducers.Fetch<[String: Int]>> {
        ValueObservation.tracking { db in try Self.counts(db, projectId: projectId) }
    }

    static func counts(_ db: Database, projectId: String) throws -> [String: Int] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT task_id, COUNT(*) AS n FROM task_comment WHERE project_id = ? GROUP BY task_id",
            arguments: [projectId]
        )
        return Dictionary(uniqueKeysWithValues: rows.map { ($0["task_id"], $0["n"]) })
    }
}
