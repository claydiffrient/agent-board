import Foundation
import GRDB

public struct ProgressStore: Sendable {
    let db: AppDatabase

    public init(_ db: AppDatabase) {
        self.db = db
    }

    @discardableResult
    public func append(taskId: String, sessionId: String?, kind: ProgressKind, text: String) throws -> ProgressEntry {
        try db.writer.write { db in
            try Self.append(db, taskId: taskId, sessionId: sessionId, kind: kind, text: text)
        }
    }

    static func append(_ db: Database, taskId: String, sessionId: String?, kind: ProgressKind, text: String) throws -> ProgressEntry {
        var entry = ProgressEntry(taskId: taskId, sessionId: sessionId, at: .nowMillis, kind: kind, text: text)
        try entry.insert(db)
        return entry
    }

    public func list(taskId: String, limit: Int = 100) throws -> [ProgressEntry] {
        try db.reader.read { db in
            try ProgressEntry.fetchAll(
                db,
                sql: "SELECT * FROM progress WHERE task_id = ? ORDER BY at DESC, id DESC LIMIT ?",
                arguments: [taskId, limit]
            )
        }
    }

    public func latest(taskId: String) throws -> ProgressEntry? {
        try db.reader.read { db in
            try ProgressEntry.fetchOne(
                db,
                sql: "SELECT * FROM progress WHERE task_id = ? ORDER BY at DESC, id DESC LIMIT 1",
                arguments: [taskId]
            )
        }
    }

    public func observe(taskId: String, limit: Int = 100) -> ValueObservation<ValueReducers.Fetch<[ProgressEntry]>> {
        ValueObservation.tracking { db in
            try ProgressEntry.fetchAll(
                db,
                sql: "SELECT * FROM progress WHERE task_id = ? ORDER BY at DESC, id DESC LIMIT ?",
                arguments: [taskId, limit]
            )
        }
    }
}
