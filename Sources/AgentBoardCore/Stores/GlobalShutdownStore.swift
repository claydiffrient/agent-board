import Foundation
import GRDB

/// Every standing wind-down order and everything the sheet needs to render it, in one read.
/// The per-project stores stay as they are; this is the cross-project view over the same tables.
public struct GlobalShutdownStore: Sendable {
    let db: AppDatabase

    public init(_ db: AppDatabase) {
        self.db = db
    }

    public func snapshot() throws -> GlobalShutdownSnapshot {
        try db.reader.read { db in try Self.snapshot(db) }
    }

    static func snapshot(_ db: Database) throws -> GlobalShutdownSnapshot {
        let orders = try ShutdownOrder.fetchAll(
            db,
            sql: """
            SELECT o.* FROM shutdown_order o
            JOIN project p ON p.id = o.project_id
            WHERE o.resolved_at IS NULL
            ORDER BY p.name COLLATE NOCASE, o.requested_at
            """
        )
        guard !orders.isEmpty else { return .empty }

        let orderIds = orders.map(\.id)
        let projectIds = Array(Set(orders.map(\.projectId)))
        let deliveries = try ShutdownDelivery.fetchAll(
            db,
            sql: """
            SELECT * FROM shutdown_delivery
            WHERE order_id IN (\(placeholders(orderIds.count)))
            ORDER BY ordered_at, session_id
            """,
            arguments: StatementArguments(orderIds)
        )
        let sessions = try AgentSession.fetchAll(
            db,
            sql: """
            SELECT * FROM agent_session
            WHERE project_id IN (\(placeholders(projectIds.count)))
            ORDER BY started_at
            """,
            arguments: StatementArguments(projectIds)
        )
        let projects = try Project.fetchAll(
            db,
            sql: "SELECT * FROM project WHERE id IN (\(placeholders(projectIds.count)))",
            arguments: StatementArguments(projectIds)
        )
        let taskIds = Array(Set(deliveries.compactMap(\.taskId)))
        let titles = try taskIds.isEmpty ? [] : Row.fetchAll(
            db,
            sql: "SELECT id, title FROM task WHERE id IN (\(placeholders(taskIds.count)))",
            arguments: StatementArguments(taskIds)
        )

        return GlobalShutdownSnapshot(
            orders: orders,
            deliveries: deliveries,
            sessions: sessions,
            projectNames: Dictionary(projects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }),
            graceSeconds: Dictionary(
                projects.map { ($0.id, $0.settings.caps.shutdownGraceSeconds) },
                uniquingKeysWith: { first, _ in first }
            ),
            taskTitles: Dictionary(
                titles.map { ($0["id"] as String, $0["title"] as String) },
                uniquingKeysWith: { first, _ in first }
            )
        )
    }

    public func observe() -> ValueObservation<ValueReducers.Fetch<GlobalShutdownSnapshot>> {
        ValueObservation.tracking { db in try Self.snapshot(db) }
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }
}
