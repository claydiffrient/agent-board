import Foundation
import GRDB

public struct ShutdownOrderStore: Sendable {
    let db: AppDatabase

    public init(_ db: AppDatabase) {
        self.db = db
    }

    /// Idempotent: an order already outstanding on the project is returned rather than duplicated.
    @discardableResult
    public func request(projectId: String, requestedBy: String, reason: String? = nil) throws -> ShutdownOrder {
        try db.writer.write { db in
            try Self.request(db, projectId: projectId, requestedBy: requestedBy, reason: reason).order
        }
    }

    static func request(
        _ db: Database, projectId: String, requestedBy: String, reason: String?
    ) throws -> (order: ShutdownOrder, isNew: Bool) {
        guard try Project.exists(db, key: projectId) else {
            throw BoardError.projectNotFound(projectId)
        }
        if let existing = try outstanding(db, projectId: projectId) {
            return (existing, false)
        }
        let order = ShutdownOrder(
            id: ShutdownOrder.newId(),
            projectId: projectId,
            requestedBy: requestedBy,
            reason: reason,
            requestedAt: .nowMillis
        )
        try order.insert(db)
        return (order, true)
    }

    public func outstanding(projectId: String) throws -> ShutdownOrder? {
        try db.reader.read { db in try Self.outstanding(db, projectId: projectId) }
    }

    static func outstanding(_ db: Database, projectId: String) throws -> ShutdownOrder? {
        try ShutdownOrder.fetchOne(
            db,
            sql: """
            SELECT * FROM shutdown_order
            WHERE project_id = ? AND resolved_at IS NULL
            ORDER BY requested_at DESC, rowid DESC LIMIT 1
            """,
            arguments: [projectId]
        )
    }

    public func isShuttingDown(projectId: String) throws -> Bool {
        try outstanding(projectId: projectId) != nil
    }

    public func get(_ id: String) throws -> ShutdownOrder? {
        try db.reader.read { db in try ShutdownOrder.fetchOne(db, key: id) }
    }

    public func history(projectId: String) throws -> [ShutdownOrder] {
        try db.reader.read { db in
            try ShutdownOrder.fetchAll(
                db,
                sql: "SELECT * FROM shutdown_order WHERE project_id = ? ORDER BY requested_at, rowid",
                arguments: [projectId]
            )
        }
    }

    @discardableResult
    public func cancel(projectId: String, by: String) throws -> ShutdownOrder? {
        try db.writer.write { db in try Self.cancel(db, projectId: projectId, by: by) }
    }

    static func cancel(_ db: Database, projectId: String, by: String) throws -> ShutdownOrder? {
        guard var order = try outstanding(db, projectId: projectId) else { return nil }
        order.resolvedAt = .nowMillis
        order.resolvedBy = by
        try order.update(db)
        return order
    }

    public func observeOutstanding(projectId: String) -> ValueObservation<ValueReducers.Fetch<ShutdownOrder?>> {
        ValueObservation.tracking { db in
            try Self.outstanding(db, projectId: projectId)
        }
    }
}
