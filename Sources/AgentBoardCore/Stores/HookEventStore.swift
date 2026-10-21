import Foundation
import GRDB

public struct HookEventStore: Sendable {
    let db: AppDatabase

    public init(_ db: AppDatabase) {
        self.db = db
    }

    @discardableResult
    public func append(sessionId: String?, event: String, payload: String) throws -> HookEventRecord {
        var record = HookEventRecord(sessionId: sessionId, event: event, payload: payload, at: .nowMillis)
        try db.writer.write { db in try record.insert(db) }
        return record
    }

    public func recent(sessionId: String, limit: Int = 100) throws -> [HookEventRecord] {
        try db.reader.read { db in
            try HookEventRecord.fetchAll(
                db,
                sql: "SELECT * FROM hook_event WHERE session_id = ? ORDER BY at DESC, id DESC LIMIT ?",
                arguments: [sessionId, limit]
            )
        }
    }

    public func mostRecent(sessionId: String, event: String) throws -> HookEventRecord? {
        try db.reader.read { db in
            try HookEventRecord.fetchOne(
                db,
                sql: "SELECT * FROM hook_event WHERE session_id = ? AND event = ? ORDER BY at DESC, id DESC LIMIT 1",
                arguments: [sessionId, event]
            )
        }
    }

    /// Rows older than this are deleted by `prune(now:)` unless their session is still active.
    public static let retentionMillis: Int64 = 14 * ArchiveSweep.millisPerDay

    /// Deletes rows older than `retentionMillis`, except those of a session still in an active
    /// state; a row with no session, or a session with no `agent_session` row, ages out. SPEC §4.
    @discardableResult
    public func prune(now: Int64 = .nowMillis) throws -> Int {
        let active = SessionState.allCases.filter(\.isActive)
        let cutoff = now - Self.retentionMillis
        return try db.writer.write { db in
            try db.execute(
                sql: """
                DELETE FROM hook_event
                WHERE at < ? AND NOT EXISTS (
                  SELECT 1 FROM agent_session s
                  WHERE s.session_id = hook_event.session_id AND s.state IN (\(databaseQuestionMarks(count: active.count)))
                )
                """,
                arguments: StatementArguments([cutoff.databaseValue] + active.map(\.databaseValue))
            )
            return db.changesCount
        }
    }
}
