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

/// One cross-project message as the human reads it: who the other project is, which way it went,
/// and whether the receiving orchestrator has pulled it yet.
///
/// `consumedAt` comes from the delivered `report` row, not from the message, so for a sent message it
/// answers "has the recipient read this?" and for a received one "has our own orchestrator read it?".
public struct MessageEntry: Codable, FetchableRecord, Identifiable, Sendable, Equatable {
    public enum Direction: String, Codable, Sendable {
        case received
        case sent
    }

    public var id: Int64
    public var direction: Direction
    public var otherProjectId: String
    public var otherProjectName: String
    public var body: String
    public var createdAt: Int64
    public var consumedAt: Int64?

    public enum CodingKeys: String, CodingKey {
        case id
        case direction
        case otherProjectId = "other_project_id"
        case otherProjectName = "other_project_name"
        case body
        case createdAt = "created_at"
        case consumedAt = "consumed_at"
    }

    public init(
        id: Int64, direction: Direction, otherProjectId: String, otherProjectName: String,
        body: String, createdAt: Int64, consumedAt: Int64? = nil
    ) {
        self.id = id
        self.direction = direction
        self.otherProjectId = otherProjectId
        self.otherProjectName = otherProjectName
        self.body = body
        self.createdAt = createdAt
        self.consumedAt = consumedAt
    }

    public var createdDate: Date { createdAt.asDate }
    public var isConsumed: Bool { consumedAt != nil }
}

extension MessageStore {
    /// Both directions of this project's message traffic, newest first, for the board to display.
    public func conversation(projectId: String) throws -> [MessageEntry] {
        try db.reader.read { db in try Self.conversation(db, projectId: projectId) }
    }

    public func observeConversation(projectId: String)
        -> ValueObservation<ValueReducers.Fetch<[MessageEntry]>>
    {
        ValueObservation.tracking { db in try Self.conversation(db, projectId: projectId) }
    }

    static func conversation(_ db: Database, projectId: String) throws -> [MessageEntry] {
        try MessageEntry.fetchAll(db, sql: conversationSQL, arguments: ["p": projectId])
    }

    /// A self-addressed message matches both arms, so the `CASE` resolves it to `received` from this
    /// project — one row, not two, which is what the single `message` row describes.
    private static let conversationSQL = """
        SELECT m.id AS id,
               CASE WHEN m.to_project_id = :p THEN 'received' ELSE 'sent' END AS direction,
               CASE WHEN m.to_project_id = :p THEN m.from_project_id ELSE m.to_project_id END
                 AS other_project_id,
               other.name AS other_project_name,
               m.body AS body,
               m.created_at AS created_at,
               r.consumed_at AS consumed_at
        FROM message m
        JOIN project other
          ON other.id = CASE WHEN m.to_project_id = :p THEN m.from_project_id ELSE m.to_project_id END
        LEFT JOIN report r ON r.id = m.report_id
        WHERE m.to_project_id = :p OR m.from_project_id = :p
        ORDER BY m.created_at DESC, m.id DESC
        """
}
