import Foundation
import GRDB

public enum MessageError: Error, Equatable, Sendable {
    case unknownSender(String)
    case unknownRecipient(String)
    case emptyBody
}

/// Cross-project messages and their delivery into the receiving project's report queue.
///
/// Sending and delivering are one transaction: a `message` row that exists without its `report` row
/// would be a message the recipient can never pull, and `list_reports` is the only way one arrives.
public struct MessageStore: Sendable {
    let db: AppDatabase

    public init(_ db: AppDatabase) {
        self.db = db
    }

    /// Writes the message and delivers it to `toProjectId`'s report queue. Nothing is written to the
    /// sending project's queue, and nothing reaches any terminal.
    @discardableResult
    public func send(
        fromProjectId: String, fromSessionId: String?, toProjectId: String, body: String
    ) throws -> (message: Message, report: Report) {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MessageError.emptyBody }
        return try db.writer.write { db in
            guard let sender = try Project.fetchOne(db, key: fromProjectId) else {
                throw MessageError.unknownSender(fromProjectId)
            }
            guard try Project.exists(db, key: toProjectId) else {
                throw MessageError.unknownRecipient(toProjectId)
            }
            var message = Message(
                fromProjectId: fromProjectId, toProjectId: toProjectId, fromSessionId: fromSessionId,
                body: text, createdAt: .nowMillis
            )
            try message.insert(db)
            // The report carries no session_id: the sending session belongs to the other project, and
            // a reader resolving it against this project's board would be resolving a stranger.
            let report = try ReportStore.insert(
                db, projectId: toProjectId, taskId: nil, sessionId: nil, kind: .message,
                body: CrossProjectMessage.deliveredBody(
                    fromProjectName: sender.name, fromProjectId: sender.id, text: text
                )
            )
            message.deliveredAt = .nowMillis
            message.reportId = report.id
            try message.update(db)
            return (message, report)
        }
    }

    public func get(_ id: Int64) throws -> Message? {
        try db.reader.read { db in try Message.fetchOne(db, key: id) }
    }

    /// Messages this project received, oldest first.
    public func inbox(projectId: String) throws -> [Message] {
        try db.reader.read { db in
            try Message.fetchAll(
                db,
                sql: "SELECT * FROM message WHERE to_project_id = ? ORDER BY created_at, id",
                arguments: [projectId]
            )
        }
    }

    /// Messages this project sent, oldest first.
    public func outbox(projectId: String) throws -> [Message] {
        try db.reader.read { db in
            try Message.fetchAll(
                db,
                sql: "SELECT * FROM message WHERE from_project_id = ? ORDER BY created_at, id",
                arguments: [projectId]
            )
        }
    }
}
