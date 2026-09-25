import Foundation
import GRDB

/// The Coordinator's one row of state and its session history (SPEC §8.2).
public struct CoordinatorStore: Sendable {
    let db: AppDatabase

    /// How many previous sessions the history offers to resume. Older rows stay in the table, so
    /// their spend is still counted; they are just no longer offered.
    public static let historyLength = 10

    public init(_ db: AppDatabase) {
        self.db = db
    }

    /// The session the next launch resumes, nil when the next launch starts a fresh one.
    public func activeSessionId() throws -> String? {
        try db.reader.read { db in
            try String.fetchOne(db, sql: "SELECT active_session_id FROM coordinator WHERE id = 1")
        }
    }

    public func setActiveSession(_ sessionId: String?) throws {
        try db.writer.write { db in
            try db.execute(sql: "UPDATE coordinator SET active_session_id = ? WHERE id = 1", arguments: [sessionId])
        }
    }

    /// The Coordinator settings' model; nil means Claude Code's default.
    public func model() throws -> String? {
        try db.reader.read { db in
            try String.fetchOne(db, sql: "SELECT model FROM coordinator WHERE id = 1")
        }
    }

    public func setModel(_ model: String?) throws {
        let model = model.flatMap { $0.isEmpty ? nil : $0 }
        try db.writer.write { db in
            try db.execute(sql: "UPDATE coordinator SET model = ? WHERE id = 1", arguments: [model])
        }
    }

    /// Every Coordinator session, most recently started first.
    public func sessions() throws -> [AgentSession] {
        try db.reader.read { db in
            try AgentSession.fetchAll(
                db,
                sql: "SELECT * FROM agent_session WHERE role = 'coordinator' ORDER BY started_at DESC"
            )
        }
    }

    /// The previous sessions a human can resume: every Coordinator session but the active one,
    /// most recent first, capped at `historyLength`.
    public func history() throws -> [AgentSession] {
        let active = try activeSessionId()
        return Array(try sessions().filter { $0.sessionId != active }.prefix(Self.historyLength))
    }
}
