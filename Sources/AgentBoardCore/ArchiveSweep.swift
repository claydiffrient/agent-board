import Foundation
import GRDB

/// Applies a project's `ArchivePolicy`. Two entry points, because the three modes fire on two
/// different things: `afterDays` is time passing, so it needs a periodic `run`; `afterEpicMerge` is
/// a single state transition, so it runs inside the transaction that moves the epic to `done`
/// (`Board.complete`). `manual` fires on neither and archives nothing here.
public struct ArchiveSweep: Sendable {
    let db: AppDatabase

    public init(_ db: AppDatabase) {
        self.db = db
    }

    public static let millisPerDay: Int64 = 86_400_000

    /// Archives everything the project's policy says is due, and returns the ids it archived.
    @discardableResult
    public func run(projectId: String, now: Int64 = .nowMillis) throws -> [String] {
        try db.writer.write { db in
            try Self.run(db, projectId: projectId, now: now)
        }
    }

    @discardableResult
    static func run(_ db: Database, projectId: String, now: Int64) throws -> [String] {
        guard let project = try Project.fetchOne(db, key: projectId) else {
            throw BoardError.projectNotFound(projectId)
        }
        let due = try self.due(db, projectId: projectId, policy: project.settings.archivePolicy, now: now)
        guard !due.isEmpty else { return [] }
        try stamp(db, ids: due, at: now)
        return due
    }

    /// The ids `run` would archive, without archiving them.
    public func due(projectId: String, policy: ArchivePolicy, now: Int64 = .nowMillis) throws -> [String] {
        try db.reader.read { db in
            try Self.due(db, projectId: projectId, policy: policy, now: now)
        }
    }

    static func due(_ db: Database, projectId: String, policy: ArchivePolicy, now: Int64) throws -> [String] {
        switch policy {
        case .manual, .afterEpicMerge:
            return []
        case .afterDays(let days):
            // Strictly greater than the threshold: a task that has been in done for exactly `days`
            // stays on the board until the next tick.
            let cutoff = now - Int64(days) * millisPerDay
            return try String.fetchAll(
                db,
                sql: """
                SELECT id FROM task
                WHERE project_id = ? AND \(archivableSQL) AND done_at < ?
                ORDER BY done_at, id
                """,
                arguments: [projectId, cutoff]
            )
        }
    }

    /// Archives every task of an epic that just merged, including the synthetic `integration` task
    /// the integrator ran on. Unlike `TaskStore.archive(ids:)` this skips rather than throws for a
    /// task outside `done` — an epic can reach `done` with a stray task parked elsewhere, and that
    /// must not roll back the merge.
    @discardableResult
    static func archiveEpic(_ db: Database, epicId: String, at: Int64) throws -> [String] {
        let ids = try String.fetchAll(
            db,
            sql: "SELECT id FROM task WHERE epic_id = ? AND \(archivableSQL) ORDER BY ordering, id",
            arguments: [epicId]
        )
        guard !ids.isEmpty else { return [] }
        try stamp(db, ids: ids, at: at)
        return ids
    }

    /// An automatic policy only ever touches an unarchived done task a human has not pulled back out.
    private static let archivableSQL = """
    column_name = 'done' AND archived_at IS NULL AND unarchived_at IS NULL AND done_at IS NOT NULL
    """

    private static func stamp(_ db: Database, ids: [String], at: Int64) throws {
        let placeholders = databaseQuestionMarks(count: ids.count)
        try db.execute(
            sql: "UPDATE task SET archived_at = ?, updated_at = ? WHERE id IN (\(placeholders))",
            arguments: StatementArguments([at, at] + ids)
        )
    }
}
