import Foundation
import GRDB

public struct ShutdownDeliveryStore: Sendable {
    let db: AppDatabase

    public static let defaultGraceSeconds = 120

    public init(_ db: AppDatabase) {
        self.db = db
    }

    @discardableResult
    public func enroll(orderId: String, sessionId: String, taskId: String?, at: Int64 = .nowMillis) throws -> ShutdownDelivery {
        try db.writer.write { db in
            try Self.enroll(db, orderId: orderId, sessionId: sessionId, taskId: taskId, at: at)
        }
    }

    @discardableResult
    static func enroll(_ db: Database, orderId: String, sessionId: String, taskId: String?, at: Int64) throws -> ShutdownDelivery {
        try db.execute(
            sql: """
            INSERT OR IGNORE INTO shutdown_delivery (order_id, session_id, task_id, ordered_at)
            VALUES (?, ?, ?, ?)
            """,
            arguments: [orderId, sessionId, taskId, at]
        )
        if taskId != nil {
            try db.execute(
                sql: "UPDATE shutdown_delivery SET task_id = COALESCE(task_id, ?) WHERE order_id = ? AND session_id = ?",
                arguments: [taskId, orderId, sessionId]
            )
        }
        guard let row = try get(db, orderId: orderId, sessionId: sessionId) else {
            throw BoardError.sessionNotFound(sessionId)
        }
        return row
    }

    /// True for exactly one caller per (order, session): whoever claims it owns handing the worker
    /// the text. Both delivery paths go through here, so a hook racing a resume cannot double-deliver.
    public func claimDelivery(
        orderId: String, sessionId: String, taskId: String?, via: ShutdownOrder.Delivery, at: Int64 = .nowMillis
    ) throws -> Bool {
        try db.writer.write { db in
            try Self.enroll(db, orderId: orderId, sessionId: sessionId, taskId: taskId, at: at)
            try db.execute(
                sql: """
                UPDATE shutdown_delivery SET delivered_at = ?, delivered_via = ?
                WHERE order_id = ? AND session_id = ? AND delivered_at IS NULL
                """,
                arguments: [at, via.rawValue, orderId, sessionId]
            )
            return db.changesCount == 1
        }
    }

    /// Undoes a claim whose delivery never landed, so the next hook can carry the order instead.
    public func releaseDelivery(orderId: String, sessionId: String) throws {
        try db.writer.write { db in
            try db.execute(
                sql: """
                UPDATE shutdown_delivery SET delivered_at = NULL, delivered_via = NULL
                WHERE order_id = ? AND session_id = ? AND acknowledged_at IS NULL
                """,
                arguments: [orderId, sessionId]
            )
        }
    }

    @discardableResult
    static func acknowledge(
        _ db: Database, orderId: String, sessionId: String, taskId: String?, note: String, at: Int64
    ) throws -> ShutdownDelivery {
        _ = try enroll(db, orderId: orderId, sessionId: sessionId, taskId: taskId, at: at)
        try db.execute(
            sql: """
            UPDATE shutdown_delivery
            SET acknowledged_at = COALESCE(acknowledged_at, ?), note = ?,
                delivered_at = COALESCE(delivered_at, ?)
            WHERE order_id = ? AND session_id = ?
            """,
            arguments: [at, note, at, orderId, sessionId]
        )
        guard let row = try get(db, orderId: orderId, sessionId: sessionId) else {
            throw BoardError.sessionNotFound(sessionId)
        }
        return row
    }

    public func get(orderId: String, sessionId: String) throws -> ShutdownDelivery? {
        try db.reader.read { db in try Self.get(db, orderId: orderId, sessionId: sessionId) }
    }

    static func get(_ db: Database, orderId: String, sessionId: String) throws -> ShutdownDelivery? {
        try ShutdownDelivery.fetchOne(
            db,
            sql: "SELECT * FROM shutdown_delivery WHERE order_id = ? AND session_id = ?",
            arguments: [orderId, sessionId]
        )
    }

    public func all(orderId: String) throws -> [ShutdownDelivery] {
        try db.reader.read { db in try Self.all(db, orderId: orderId) }
    }

    static func all(_ db: Database, orderId: String) throws -> [ShutdownDelivery] {
        try ShutdownDelivery.fetchAll(
            db,
            sql: "SELECT * FROM shutdown_delivery WHERE order_id = ? ORDER BY ordered_at, session_id",
            arguments: [orderId]
        )
    }

    public func progress(
        orderId: String, graceSeconds: Int = defaultGraceSeconds, awake: AwakeElapsed = SleepLedger.shared.reading()
    ) throws -> ShutdownProgress {
        try db.reader.read { db in
            Self.progress(try Self.all(db, orderId: orderId), orderId: orderId, graceSeconds: graceSeconds, awake: awake)
        }
    }

    /// The grace period is awake time, not elapsed time: a worker on a sleeping machine has not
    /// failed to answer, it never got the chance.
    static func progress(
        _ rows: [ShutdownDelivery], orderId: String, graceSeconds: Int, awake: AwakeElapsed
    ) -> ShutdownProgress {
        let deadline = Int64(graceSeconds) * 1000
        return ShutdownProgress(
            orderId: orderId,
            total: rows.count,
            acknowledged: rows.filter(\.isAcknowledged).count,
            overdue: rows
                .filter { !$0.isAcknowledged && awake.millisAwake(since: $0.orderedAt) >= deadline }
                .map(\.sessionId)
        )
    }

    public func observeAll(orderId: String) -> ValueObservation<ValueReducers.Fetch<[ShutdownDelivery]>> {
        ValueObservation.tracking { db in try Self.all(db, orderId: orderId) }
    }

    public func observeProgress(
        orderId: String, graceSeconds: Int = defaultGraceSeconds
    ) -> ValueObservation<ValueReducers.Fetch<ShutdownProgress>> {
        ValueObservation.tracking { db in
            Self.progress(
                try Self.all(db, orderId: orderId), orderId: orderId, graceSeconds: graceSeconds,
                awake: SleepLedger.shared.reading()
            )
        }
    }
}
