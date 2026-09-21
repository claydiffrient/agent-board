import Foundation
import GRDB

public struct TaskStore: Sendable {
    let db: AppDatabase

    public init(_ db: AppDatabase) {
        self.db = db
    }

    @discardableResult
    public func create(
        projectId: String, title: String, body: String?, acceptance: String?, priority: String?,
        column: TaskColumn, origin: TaskOrigin, epicId: String?, model: String? = nil
    ) throws -> Task {
        try db.writer.write { db in
            try Self.insert(
                db, projectId: projectId, title: title, body: body, acceptance: acceptance,
                priority: priority, column: column, origin: origin, epicId: epicId, model: model
            )
        }
    }

    static func insert(
        _ db: Database, projectId: String, title: String, body: String?, acceptance: String?,
        priority: String?, column: TaskColumn, origin: TaskOrigin, epicId: String?, model: String? = nil
    ) throws -> Task {
        let now = Int64.nowMillis
        let task = Task(
            id: Task.newId(),
            projectId: projectId,
            epicId: epicId,
            title: title,
            body: body,
            acceptance: acceptance,
            priority: priority,
            column: column,
            ordering: try endOrdering(db, projectId: projectId, column: column, excluding: nil),
            origin: origin,
            createdAt: now,
            updatedAt: now,
            model: model,
            doneAt: column == .done ? now : nil,
            landing: column == .done ? .noBranch : nil
        )
        try task.insert(db)
        return task
    }

    public func get(_ id: String, includeArchived: Bool = true) throws -> Task? {
        try db.reader.read { db in
            guard let task = try Task.fetchOne(db, key: id) else { return nil }
            return includeArchived || !task.isArchived ? task : nil
        }
    }

    public func list(
        projectId: String, column: TaskColumn? = nil, epicId: String? = nil, includeArchived: Bool = false
    ) throws -> [Task] {
        try db.reader.read { db in
            try Self.list(db, projectId: projectId, column: column, epicId: epicId, includeArchived: includeArchived)
        }
    }


    static func list(
        _ db: Database, projectId: String, column: TaskColumn?, epicId: String?, includeArchived: Bool = false
    ) throws -> [Task] {
        var sql = "SELECT * FROM task WHERE project_id = ?"
        var arguments: StatementArguments = [projectId]
        if !includeArchived {
            sql += " AND archived_at IS NULL"
        }
        if let column {
            sql += " AND column_name = ?"
            arguments += [column]
        }
        if let epicId {
            sql += " AND epic_id = ?"
            arguments += [epicId]
        }
        if !includeArchived {
            sql += " AND archived_at IS NULL"
        }
        sql += " ORDER BY \(TaskColumn.orderingSQL), ordering, created_at"
        return try Task.fetchAll(db, sql: sql, arguments: arguments)
    }

    public static let branchPrefix = "agentboard/"

    public static func branchName(for id: String) -> String { branchPrefix + id }

    public func setEpic(_ id: String, epicId: String?) throws {
        try db.writer.write { db in try Self.setEpic(db, id, epicId: epicId) }
    }

    static func setEpic(_ db: Database, _ id: String, epicId: String?) throws {
        guard try Task.exists(db, key: id) else {
            throw BoardError.taskNotFound(id)
        }
        try db.execute(
            sql: "UPDATE task SET epic_id = ?, updated_at = ? WHERE id = ?",
            arguments: [epicId, Int64.nowMillis, id]
        )
    }

    public func update(_ task: Task) throws {
        var task = task
        task.updatedAt = .nowMillis
        try db.writer.write { db in try task.update(db) }
    }

    public func move(_ id: String, to column: TaskColumn, before: String? = nil) throws {
        try db.writer.write { db in
            try Self.move(db, id, to: column, before: before)
        }
    }

    static func move(_ db: Database, _ id: String, to column: TaskColumn, before: String?) throws {
        guard let task = try Task.fetchOne(db, key: id) else {
            throw BoardError.taskNotFound(id)
        }
        let ordering: Double
        if let before, before != id, let anchor = try Task.fetchOne(db, key: before), anchor.column == column {
            let previous = try Double.fetchOne(
                db,
                sql: """
                SELECT MAX(ordering) FROM task
                WHERE project_id = ? AND column_name = ? AND ordering < ? AND id != ?
                """,
                arguments: [task.projectId, column, anchor.ordering, id]
            )
            ordering = previous.map { ($0 + anchor.ordering) / 2 } ?? anchor.ordering - 1
        } else {
            ordering = try endOrdering(db, projectId: task.projectId, column: column, excluding: id)
        }
        let now = Int64.nowMillis
        try db.execute(
            sql: "UPDATE task SET column_name = ?, ordering = ?, updated_at = ? WHERE id = ?",
            arguments: [column, ordering, now, id]
        )
        try stampDoneTransition(db, id, entering: column, from: task.column, at: now)
    }

    /// `done_at` is the only reliable measure of time-in-done: reordering inside `done`, archiving
    /// and every other edit move `updated_at`. Leaving `done` clears it along with the manual
    /// unarchive, so a reopened task starts the policy clock — and the policy itself — from scratch.
    ///
    /// Entering `done` also arms `landing` at `.pending`, here rather than in `Board.accept`, so
    /// that every route into the column is covered — a human dragging a card across the board is
    /// otherwise a second way for `done` to mean "and the work is nowhere" in silence. The accept
    /// overwrites it once git has answered.
    static func stampDoneTransition(
        _ db: Database, _ id: String, entering: TaskColumn, from: TaskColumn, at: Int64
    ) throws {
        switch (from, entering) {
        case (.done, .done):
            return
        case (_, .done):
            try db.execute(
                sql: "UPDATE task SET done_at = ?, landing = ?, landing_detail = NULL WHERE id = ?",
                arguments: [at, TaskLanding.pending.rawValue, id]
            )
        default:
            try db.execute(
                sql: """
                UPDATE task SET done_at = NULL, unarchived_at = NULL, landing = NULL, landing_detail = NULL
                WHERE id = ?
                """,
                arguments: [id]
            )
        }
    }

    static func endOrdering(_ db: Database, projectId: String, column: TaskColumn, excluding id: String?) throws -> Double {
        let max = try Double.fetchOne(
            db,
            sql: "SELECT MAX(ordering) FROM task WHERE project_id = ? AND column_name = ? AND id IS NOT ?",
            arguments: [projectId, column, id]
        )
        return (max ?? 0) + 1
    }

    public func setDeps(_ id: String, dependsOn: [String]) throws {
        try db.writer.write { db in
            try db.execute(sql: "DELETE FROM task_dep WHERE task_id = ?", arguments: [id])
            for dep in Set(dependsOn) where dep != id {
                try TaskDep(taskId: id, dependsOn: dep).insert(db)
            }
        }
    }

    public func deps(of id: String) throws -> [String] {
        try db.reader.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT depends_on FROM task_dep WHERE task_id = ? ORDER BY depends_on",
                arguments: [id]
            )
        }
    }

    public func dependents(of id: String) throws -> [String] {
        try db.reader.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT task_id FROM task_dep WHERE depends_on = ? ORDER BY task_id",
                arguments: [id]
            )
        }
    }

    @discardableResult
    public func refreshReadiness(projectId: String) throws -> [String] {
        try db.writer.write { db in
            try Self.refreshReadiness(db, projectId: projectId)
        }
    }

    static func refreshReadiness(_ db: Database, projectId: String) throws -> [String] {
        let unmetDeps = """
        EXISTS (
          SELECT 1 FROM task_dep d JOIN task dep ON dep.id = d.depends_on
          WHERE d.task_id = task.id AND dep.column_name != 'done'
        )
        """
        let toReady = try String.fetchAll(
            db,
            sql: "SELECT id FROM task WHERE project_id = ? AND column_name = 'backlog' AND NOT \(unmetDeps)",
            arguments: [projectId]
        )
        let toBacklog = try String.fetchAll(
            db,
            sql: "SELECT id FROM task WHERE project_id = ? AND column_name = 'ready' AND \(unmetDeps)",
            arguments: [projectId]
        )
        for id in toReady {
            try move(db, id, to: .ready, before: nil)
        }
        for id in toBacklog {
            try move(db, id, to: .backlog, before: nil)
        }
        return toReady + toBacklog
    }

    public func setBlocked(_ id: String, _ blocked: Bool, reason: String?) throws {
        try db.writer.write { db in
            try Self.setBlocked(db, id, blocked, reason: reason)
        }
    }

    static func setBlocked(_ db: Database, _ id: String, _ blocked: Bool, reason: String?) throws {
        try db.execute(
            sql: "UPDATE task SET blocked = ?, blocked_reason = ?, updated_at = ? WHERE id = ?",
            arguments: [blocked, blocked ? reason : nil, Int64.nowMillis, id]
        )
    }

    public func setFailed(_ id: String, _ failed: Bool, reason: String?) throws {
        try db.writer.write { db in
            try Self.setFailed(db, id, failed, reason: reason)
        }
    }

    static func setFailed(_ db: Database, _ id: String, _ failed: Bool, reason: String?) throws {
        try db.execute(
            sql: "UPDATE task SET failed = ?, failure_reason = ?, updated_at = ? WHERE id = ?",
            arguments: [failed, failed ? reason : nil, Int64.nowMillis, id]
        )
    }

    public func setLanding(_ id: String, _ landing: TaskLanding, detail: String?) throws {
        try db.writer.write { db in
            try Self.setLanding(db, id, landing, detail: detail)
        }
    }

    static func setLanding(_ db: Database, _ id: String, _ landing: TaskLanding, detail: String?) throws {
        try db.execute(
            sql: "UPDATE task SET landing = ?, landing_detail = ?, updated_at = ? WHERE id = ?",
            arguments: [landing.rawValue, detail, Int64.nowMillis, id]
        )
    }

    /// Every `done` task the human still has to place somewhere, oldest acceptance first.
    /// `no_branch` and `landed` are excluded; a NULL predates the tracking and claims nothing.
    /// Archived tasks are included: the incident that went undetected longest was an archived one,
    /// and hiding a card does not put its commits anywhere.
    public func awaitingLanding(projectId: String) throws -> [BoardTask] {
        try db.reader.read { db in
            try BoardTask.fetchAll(
                db,
                sql: """
                SELECT * FROM task
                WHERE project_id = ? AND column_name = 'done' AND landing IN ('pending', 'unlanded')
                ORDER BY done_at
                """,
                arguments: [projectId]
            )
        }
    }

    /// Hides a done task from the board by stamping `archived_at`. Nothing else changes:
    /// the task's branch, worktree, sessions, reports and progress rows are all left in place —
    /// archiving is a view filter, not cleanup, and reaping those belongs elsewhere.
    /// Throws `BoardError.archiveRequiresDone` for a task outside `done`.
    public func archive(_ id: String) throws {
        try archive(ids: [id])
    }

    /// Archives every task in one transaction; if any is not in `done`, none are archived.
    public func archive(ids: [String]) throws {
        try db.writer.write { db in
            let at = Int64.nowMillis
            for id in ids {
                try Self.archive(db, id, at: at)
            }
        }
    }

    static func archive(_ db: Database, _ id: String, at: Int64) throws {
        guard let task = try Task.fetchOne(db, key: id) else {
            throw BoardError.taskNotFound(id)
        }
        guard task.column == .done else {
            throw BoardError.archiveRequiresDone(taskId: id, column: task.column)
        }
        guard task.archivedAt == nil else { return }
        try db.execute(
            sql: "UPDATE task SET archived_at = ?, updated_at = ? WHERE id = ?",
            arguments: [at, at, id]
        )
    }

    /// Clears `archived_at`. Always allowed, whatever column the task now sits in.
    /// Stamping `unarchived_at` is what stops the next `ArchiveSweep` tick from undoing this.
    public func unarchive(_ id: String) throws {
        try db.writer.write { db in
            guard try Task.exists(db, key: id) else { throw BoardError.taskNotFound(id) }
            let now = Int64.nowMillis
            try db.execute(
                sql: "UPDATE task SET archived_at = NULL, unarchived_at = ?, updated_at = ? WHERE id = ?",
                arguments: [now, now, id]
            )
        }
    }

    public func delete(_ id: String) throws {
        try db.writer.write { db in
            try Self.delete(db, id)
        }
    }

    static func delete(_ db: Database, _ id: String) throws {
        try db.execute(sql: "DELETE FROM task_dep WHERE task_id = ? OR depends_on = ?", arguments: [id, id])
        try db.execute(sql: "DELETE FROM progress WHERE task_id = ?", arguments: [id])
        try db.execute(sql: "UPDATE report SET task_id = NULL WHERE task_id = ?", arguments: [id])
        try db.execute(sql: "UPDATE agent_session SET task_id = NULL WHERE task_id = ?", arguments: [id])
        try db.execute(sql: "UPDATE token_grant SET task_id = NULL WHERE task_id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM note_link WHERE task_id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM task WHERE id = ?", arguments: [id])
    }

    public func observe(
        projectId: String, includeArchived: Bool = false
    ) -> ValueObservation<ValueReducers.Fetch<[Task]>> {
        ValueObservation.tracking { db in
            try Self.list(db, projectId: projectId, column: nil, epicId: nil, includeArchived: includeArchived)
        }
    }
}

public enum BoardError: Error, Equatable, Sendable {
    case taskNotFound(String)
    case sessionNotFound(String)
    case projectNotFound(String)
    case tokenNotFound(String)
    case invalidTransition(taskId: String, from: TaskColumn, to: TaskColumn)
    case approvalNotFound(String)
    case approvalAlreadyResolved(String)
    case epicNotFound(String)
    case workspaceNotFound(String)
    /// `createEpic` was handed a `dependsOn` index that is out of range or points at the task itself.
    case invalidEpicDependency(taskIndex: Int, dependsOn: Int)
    case noShutdownOrder(String)
    /// Only a task in `done` may be archived; archiving live work would hide it from the board.
    case archiveRequiresDone(taskId: String, column: TaskColumn)
    /// A setup row was resolved twice, or something ended it while its worktree was being prepared.
    case sessionNotInSetup(String, SessionState)
    /// `done` and `abandoned` are both terminal; one never silently becomes the other.
    case epicAlreadyClosed(epicId: String, state: EpicState)
    /// Closing would have left these sessions running against a closed epic.
    case epicHasRunningWorkers(epicId: String, sessionIds: [String])
}
