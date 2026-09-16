import Foundation
import GRDB

public struct WorkspaceStore: Sendable {
    let db: AppDatabase

    public init(_ db: AppDatabase) {
        self.db = db
    }

    @discardableResult
    public func create(name: String) throws -> Workspace {
        try db.writer.write { db in
            let last = try Double.fetchOne(db, sql: "SELECT MAX(ordering) FROM workspace") ?? 0
            let workspace = Workspace(
                id: Workspace.newId(),
                name: name,
                ordering: last + 1,
                createdAt: .nowMillis
            )
            try workspace.insert(db)
            return workspace
        }
    }

    public func get(_ id: String) throws -> Workspace? {
        try db.reader.read { db in try Workspace.fetchOne(db, key: id) }
    }

    public func list() throws -> [Workspace] {
        try db.reader.read { db in try Self.list(db) }
    }

    static func list(_ db: Database) throws -> [Workspace] {
        try Workspace.fetchAll(db, sql: "SELECT * FROM workspace ORDER BY ordering, name COLLATE NOCASE, id")
    }

    public func rename(_ id: String, to name: String) throws {
        try db.writer.write { db in
            guard try Workspace.exists(db, key: id) else { throw BoardError.workspaceNotFound(id) }
            try db.execute(sql: "UPDATE workspace SET name = ? WHERE id = ?", arguments: [name, id])
        }
    }

    public func setOrdering(_ id: String, _ ordering: Double) throws {
        try db.writer.write { db in
            guard try Workspace.exists(db, key: id) else { throw BoardError.workspaceNotFound(id) }
            try db.execute(sql: "UPDATE workspace SET ordering = ? WHERE id = ?", arguments: [ordering, id])
        }
    }

    /// Projects in the workspace survive; they become ungrouped.
    public func delete(_ id: String) throws {
        try db.writer.write { db in
            try db.execute(sql: "UPDATE project SET workspace_id = NULL WHERE workspace_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM workspace WHERE id = ?", arguments: [id])
        }
    }

    /// `workspaceId: nil` moves the project to the ungrouped section.
    public func assign(projectId: String, workspaceId: String?) throws {
        try db.writer.write { db in
            guard try Project.exists(db, key: projectId) else { throw BoardError.projectNotFound(projectId) }
            if let workspaceId, try !Workspace.exists(db, key: workspaceId) {
                throw BoardError.workspaceNotFound(workspaceId)
            }
            try db.execute(
                sql: "UPDATE project SET workspace_id = ? WHERE id = ?",
                arguments: [workspaceId, projectId]
            )
        }
    }

    public func observe() -> ValueObservation<ValueReducers.Fetch<[Workspace]>> {
        ValueObservation.tracking { db in try Self.list(db) }
    }
}
