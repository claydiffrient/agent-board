import Foundation
import GRDB

public struct EpicStore: Sendable {
    let db: AppDatabase

    public init(_ db: AppDatabase) {
        self.db = db
    }

    @discardableResult
    public func create(projectId: String, title: String, goal: String?) throws -> Epic {
        try db.writer.write { db in
            try Self.insert(db, projectId: projectId, title: title, goal: goal)
        }
    }

    static func insert(_ db: Database, projectId: String, title: String, goal: String?) throws -> Epic {
        let id = Epic.newId()
        let epic = Epic(
            id: id,
            projectId: projectId,
            title: title,
            goal: goal,
            branch: branchName(for: id),
            state: .planning,
            createdAt: .nowMillis
        )
        try epic.insert(db)
        return epic
    }

    public static let branchPrefix = "agentboard/epic-"

    public static func branchName(for id: String) -> String { branchPrefix + id }

    public func get(_ id: String) throws -> Epic? {
        try db.reader.read { db in try Epic.fetchOne(db, key: id) }
    }

    public func list(projectId: String) throws -> [Epic] {
        try db.reader.read { db in try Self.list(db, projectId: projectId) }
    }

    static func list(_ db: Database, projectId: String) throws -> [Epic] {
        try Epic.fetchAll(
            db,
            sql: "SELECT * FROM epic WHERE project_id = ? ORDER BY created_at, rowid",
            arguments: [projectId]
        )
    }

    public func setState(_ id: String, _ state: EpicState) throws {
        try db.writer.write { db in try Self.setState(db, id, state) }
    }

    static func setState(_ db: Database, _ id: String, _ state: EpicState) throws {
        guard try Epic.exists(db, key: id) else {
            throw BoardError.epicNotFound(id)
        }
        try db.execute(sql: "UPDATE epic SET state = ? WHERE id = ?", arguments: [state, id])
    }

    /// nil clears the override, so the epic's tasks go back to inheriting the project's level.
    public func setReviewLevel(_ id: String, _ level: ReviewLevel?) throws {
        try db.writer.write { db in
            guard try Epic.exists(db, key: id) else { throw BoardError.epicNotFound(id) }
            try db.execute(
                sql: "UPDATE epic SET review_level = ? WHERE id = ?",
                arguments: [level, id]
            )
        }
    }

    public func observe(projectId: String) -> ValueObservation<ValueReducers.Fetch<[Epic]>> {
        ValueObservation.tracking { db in
            try Self.list(db, projectId: projectId)
        }
    }
}
