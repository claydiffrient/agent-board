import Foundation
import GRDB

public struct ReportStore: Sendable {
    let db: AppDatabase

    public init(_ db: AppDatabase) {
        self.db = db
    }

    @discardableResult
    public func insert(projectId: String, taskId: String?, sessionId: String?, kind: ReportKind, body: String) throws -> Report {
        try db.writer.write { db in
            try Self.insert(db, projectId: projectId, taskId: taskId, sessionId: sessionId, kind: kind, body: body)
        }
    }

    static func insert(_ db: Database, projectId: String, taskId: String?, sessionId: String?, kind: ReportKind, body: String) throws -> Report {
        var report = Report(projectId: projectId, taskId: taskId, sessionId: sessionId, kind: kind, body: body, createdAt: .nowMillis)
        try report.insert(db)
        return report
    }

    public func unconsumed(projectId: String) throws -> [Report] {
        try db.reader.read { db in
            try Self.unconsumed(db, projectId: projectId)
        }
    }

    static func unconsumed(_ db: Database, projectId: String) throws -> [Report] {
        try Report.fetchAll(
            db,
            sql: "SELECT * FROM report WHERE project_id = ? AND consumed_at IS NULL ORDER BY created_at, id",
            arguments: [projectId]
        )
    }

    public func get(_ id: Int64) throws -> Report? {
        try db.reader.read { db in try Report.fetchOne(db, key: id) }
    }

    /// The `complete` report this session already filed for this task, if any. Read inside
    /// `Board.complete`'s write transaction so a resent `report_complete` cannot insert a second
    /// one — see `TaskCompletion`.
    static func completion(_ db: Database, taskId: String, sessionId: String) throws -> Report? {
        try Report.fetchOne(
            db,
            sql: "SELECT * FROM report WHERE task_id = ? AND session_id = ? AND kind = ? ORDER BY id LIMIT 1",
            arguments: [taskId, sessionId, ReportKind.complete.rawValue]
        )
    }

    public func latest(taskId: String) throws -> Report? {
        try db.reader.read { db in
            try Report.fetchOne(
                db,
                sql: "SELECT * FROM report WHERE task_id = ? ORDER BY created_at DESC, id DESC LIMIT 1",
                arguments: [taskId]
            )
        }
    }

    public func consume(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try db.writer.write { db in
            let placeholders = databaseQuestionMarks(count: ids.count)
            try db.execute(
                sql: "UPDATE report SET consumed_at = ? WHERE consumed_at IS NULL AND id IN (\(placeholders))",
                arguments: [Int64.nowMillis] + StatementArguments(ids)
            )
        }
    }

    @discardableResult
    public func consumeAll(projectId: String) throws -> [Report] {
        try db.writer.write { db in
            let pending = try Self.unconsumed(db, projectId: projectId)
            guard !pending.isEmpty else { return [] }
            try db.execute(
                sql: "UPDATE report SET consumed_at = ? WHERE project_id = ? AND consumed_at IS NULL",
                arguments: [Int64.nowMillis, projectId]
            )
            return pending
        }
    }

    public func unconsumedCount(projectId: String) throws -> Int {
        try db.reader.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM report WHERE project_id = ? AND consumed_at IS NULL",
                arguments: [projectId]
            ) ?? 0
        }
    }

    public func observeUnconsumed(projectId: String) -> ValueObservation<ValueReducers.Fetch<[Report]>> {
        ValueObservation.tracking { db in
            try Self.unconsumed(db, projectId: projectId)
        }
    }
}
