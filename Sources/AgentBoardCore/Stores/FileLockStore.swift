import Foundation
import GRDB

public struct FileLockStore: Sendable {
    let db: AppDatabase

    public init(_ db: AppDatabase) {
        self.db = db
    }

    /// Claims `path` for `sessionId`, or reports who holds it.
    ///
    /// A lock whose holder is no longer an active session is taken rather than waited on: the row
    /// outlives the process that wrote it, and a dead agent's claim would otherwise block the
    /// checkout forever.
    @discardableResult
    public func acquire(
        projectId: String, path: String, sessionId: String, taskId: String? = nil, now: Int64 = .nowMillis
    ) throws -> FileLockOutcome {
        try db.writer.write { db in
            if let existing = try Self.fetch(db, projectId: projectId, path: path) {
                if existing.sessionId == sessionId { return .acquired(existing) }
                if try Self.isLive(db, sessionId: existing.sessionId) { return .heldBy(existing) }
                try Self.delete(db, projectId: projectId, path: path)
            }
            let lock = FileLock(projectId: projectId, path: path, sessionId: sessionId, taskId: taskId, heldSince: now)
            try lock.insert(db)
            return .acquired(lock)
        }
    }

    public func holder(projectId: String, path: String) throws -> FileLock? {
        try db.reader.read { db in try Self.fetch(db, projectId: projectId, path: path) }
    }

    public func held(projectId: String) throws -> [FileLock] {
        try db.reader.read { db in
            try FileLock.fetchAll(
                db,
                sql: "SELECT * FROM file_lock WHERE project_id = ? ORDER BY held_since",
                arguments: [projectId]
            )
        }
    }

    public func release(projectId: String, path: String, sessionId: String) throws {
        try db.writer.write { db in
            try db.execute(
                sql: "DELETE FROM file_lock WHERE project_id = ? AND path = ? AND session_id = ?",
                arguments: [projectId, path, sessionId]
            )
        }
    }

    @discardableResult
    public func releaseAll(sessionId: String) throws -> Int {
        try db.writer.write { db in try Self.releaseAll(db, sessionId: sessionId) }
    }

    @discardableResult
    static func releaseAll(_ db: Database, sessionId: String) throws -> Int {
        try db.execute(sql: "DELETE FROM file_lock WHERE session_id = ?", arguments: [sessionId])
        return db.changesCount
    }

    /// Every lock whose holder is not an active session — a worker the last run of the app never
    /// saw end, or one whose row is gone entirely. Run at launch, the way orphaned setup rows are.
    @discardableResult
    public func sweepStale() throws -> [FileLock] {
        try db.writer.write { db in
            let all = try FileLock.fetchAll(db, sql: "SELECT * FROM file_lock")
            var swept: [FileLock] = []
            for lock in all where try !Self.isLive(db, sessionId: lock.sessionId) {
                try Self.delete(db, projectId: lock.projectId, path: lock.path)
                swept.append(lock)
            }
            return swept
        }
    }

    private static func fetch(_ db: Database, projectId: String, path: String) throws -> FileLock? {
        try FileLock.fetchOne(
            db,
            sql: "SELECT * FROM file_lock WHERE project_id = ? AND path = ?",
            arguments: [projectId, path]
        )
    }

    private static func delete(_ db: Database, projectId: String, path: String) throws {
        try db.execute(
            sql: "DELETE FROM file_lock WHERE project_id = ? AND path = ?",
            arguments: [projectId, path]
        )
    }

    private static func isLive(_ db: Database, sessionId: String) throws -> Bool {
        guard let session = try AgentSession.fetchOne(db, key: sessionId) else { return false }
        return session.state.isActive
    }
}
