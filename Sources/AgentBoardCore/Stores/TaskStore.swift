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
        column: TaskColumn, origin: TaskOrigin, epicId: String?
    ) throws -> Task {
        try db.writer.write { db in
            try Self.insert(
                db, projectId: projectId, title: title, body: body, acceptance: acceptance,
                priority: priority, column: column, origin: origin, epicId: epicId
            )
        }
    }

    static func insert(
        _ db: Database, projectId: String, title: String, body: String?, acceptance: String?,
        priority: String?, column: TaskColumn, origin: TaskOrigin, epicId: String?
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
            updatedAt: now
        )
        try task.insert(db)
        return task
    }

    public func get(_ id: String) throws -> Task? {
        try db.reader.read { db in try Task.fetchOne(db, key: id) }
    }

    public func list(projectId: String, column: TaskColumn? = nil, epicId: String? = nil) throws -> [Task] {
        try db.reader.read { db in
            try Self.list(db, projectId: projectId, column: column, epicId: epicId)
        }
    }

    static func list(_ db: Database, projectId: String, column: TaskColumn?, epicId: String?) throws -> [Task] {
        var sql = "SELECT * FROM task WHERE project_id = ?"
        var arguments: StatementArguments = [projectId]
        if let column {
            sql += " AND column_name = ?"
            arguments += [column]
        }
        if let epicId {
            sql += " AND epic_id = ?"
            arguments += [epicId]
        }
        sql += " ORDER BY \(TaskColumn.orderingSQL), ordering, created_at"
        return try Task.fetchAll(db, sql: sql, arguments: arguments)
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
        try db.execute(
            sql: "UPDATE task SET column_name = ?, ordering = ?, updated_at = ? WHERE id = ?",
            arguments: [column, ordering, Int64.nowMillis, id]
        )
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

    public func delete(_ id: String) throws {
        try db.writer.write { db in
            try db.execute(sql: "DELETE FROM task_dep WHERE task_id = ? OR depends_on = ?", arguments: [id, id])
            try db.execute(sql: "DELETE FROM progress WHERE task_id = ?", arguments: [id])
            try db.execute(sql: "UPDATE report SET task_id = NULL WHERE task_id = ?", arguments: [id])
            try db.execute(sql: "UPDATE agent_session SET task_id = NULL WHERE task_id = ?", arguments: [id])
            try db.execute(sql: "UPDATE token_grant SET task_id = NULL WHERE task_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM note_link WHERE task_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM task WHERE id = ?", arguments: [id])
        }
    }

    public func observe(projectId: String) -> ValueObservation<ValueReducers.Fetch<[Task]>> {
        ValueObservation.tracking { db in
            try Self.list(db, projectId: projectId, column: nil, epicId: nil)
        }
    }
}

public enum BoardError: Error, Equatable, Sendable {
    case taskNotFound(String)
    case sessionNotFound(String)
    case projectNotFound(String)
    case tokenNotFound(String)
    case invalidTransition(taskId: String, from: TaskColumn, to: TaskColumn)
}
