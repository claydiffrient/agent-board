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

    public func prune(olderThan cutoff: Int64) throws {
        try db.writer.write { db in
            try db.execute(sql: "DELETE FROM hook_event WHERE at < ?", arguments: [cutoff])
        }
    }
}
