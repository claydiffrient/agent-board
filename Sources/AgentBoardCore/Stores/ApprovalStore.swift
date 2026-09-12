import Foundation
import GRDB

public struct ApprovalStore: Sendable {
    let db: AppDatabase

    public init(_ db: AppDatabase) {
        self.db = db
    }

    @discardableResult
    public func create(
        projectId: String, kind: ApprovalKind, taskId: String?, epicId: String?,
        requestedBy: String, reason: String?
    ) throws -> Approval {
        try db.writer.write { db in
            try Self.insert(
                db, projectId: projectId, kind: kind, taskId: taskId, epicId: epicId,
                requestedBy: requestedBy, reason: reason
            )
        }
    }

    static func insert(
        _ db: Database, projectId: String, kind: ApprovalKind, taskId: String?, epicId: String?,
        requestedBy: String, reason: String?
    ) throws -> Approval {
        let approval = Approval(
            id: Approval.newId(),
            projectId: projectId,
            kind: kind,
            taskId: taskId,
            epicId: epicId,
            requestedBy: requestedBy,
            reason: reason,
            createdAt: .nowMillis
        )
        try approval.insert(db)
        return approval
    }

    public func get(_ id: String) throws -> Approval? {
        try db.reader.read { db in try Approval.fetchOne(db, key: id) }
    }

    public func pending(projectId: String) throws -> [Approval] {
        try db.reader.read { db in try Self.pending(db, projectId: projectId) }
    }

    static func pending(_ db: Database, projectId: String) throws -> [Approval] {
        try Approval.fetchAll(
            db,
            sql: "SELECT * FROM approval WHERE project_id = ? AND resolved_at IS NULL ORDER BY created_at, rowid",
            arguments: [projectId]
        )
    }

    public func pendingSpawn(taskId: String) throws -> Approval? {
        try db.reader.read { db in try Self.pendingSpawn(db, taskId: taskId) }
    }

    static func pendingSpawn(_ db: Database, taskId: String) throws -> Approval? {
        try Approval.fetchOne(
            db,
            sql: """
            SELECT * FROM approval
            WHERE task_id = ? AND kind = 'spawn' AND resolved_at IS NULL
            ORDER BY created_at, rowid LIMIT 1
            """,
            arguments: [taskId]
        )
    }

    @discardableResult
    public func resolve(_ id: String, _ resolution: ApprovalResolution) throws -> Approval {
        try db.writer.write { db in try Self.resolve(db, id, resolution) }
    }

    static func resolve(_ db: Database, _ id: String, _ resolution: ApprovalResolution) throws -> Approval {
        guard var approval = try Approval.fetchOne(db, key: id) else {
            throw BoardError.approvalNotFound(id)
        }
        guard approval.isPending else {
            throw BoardError.approvalAlreadyResolved(id)
        }
        approval.resolvedAt = .nowMillis
        approval.resolution = resolution
        try approval.update(db)
        return approval
    }

    public func observePending(projectId: String) -> ValueObservation<ValueReducers.Fetch<[Approval]>> {
        ValueObservation.tracking { db in
            try Self.pending(db, projectId: projectId)
        }
    }
}
