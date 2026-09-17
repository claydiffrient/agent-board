import Foundation
import GRDB

/// Why a project is waiting on a human. Declaration order is severity order: a pending approval
/// blocks work outright, while an unacknowledged shutdown is a straggler to chase.
public enum AttentionReason: String, Sendable, Codable, CaseIterable, Equatable {
    /// An approval nobody has granted or denied. Whatever it gates cannot proceed.
    case pendingApproval
    /// A worker called `report_blocked` and stopped until a human answers (SPEC D15).
    case blockedWorker
    /// Reports queued for an orchestrator that is not running, so nothing will pull them.
    case strandedReports
    /// A shutdown order past its grace period whose deliveries are still unacknowledged.
    case overdueShutdown

    var severity: Int { Self.allCases.firstIndex(of: self)! }
}

public struct AttentionCause: Sendable, Equatable, Identifiable {
    public var reason: AttentionReason
    public var count: Int
    /// The single most useful specific, when there is one — currently the blocked task's title.
    public var detail: String?

    public init(reason: AttentionReason, count: Int, detail: String? = nil) {
        self.reason = reason
        self.count = count
        self.detail = detail
    }

    public var id: String { reason.rawValue }
}

/// Whether one project needs the human, and why. Derived entirely from rows in the database, so it
/// is the same answer after a relaunch as it was before one — unlike the worker-lifecycle
/// notifications, which only exist at the instant they happen.
///
/// Distinct from `AttentionSelection`, which picks out individual stalled or blocked *tasks* for the
/// orchestrator console. This is the per-project roll-up the sidebar badge and the notifier share.
///
/// **A failed task does not raise this, deliberately.** `Board.fail` writes an unconsumed `report`
/// row of kind `failed` alongside `task.failed`, so the failure is already addressed to the
/// orchestrator, which is the agent whose job it is to retry, re-scope or escalate it. Counting it
/// here would ping the human for every retryable failure. When there genuinely is nobody to handle
/// it, `strandedReports` raises the signal on that same report — the condition built for exactly
/// this case.
public struct ProjectAttention: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// Severity order, strongest first. Empty means the project does not need the human.
    public var causes: [AttentionCause]

    public init(id: String, name: String, causes: [AttentionCause]) {
        self.id = id
        self.name = name
        self.causes = causes
    }

    public var needsAttention: Bool { !causes.isEmpty }

    /// What a badge shows: every waiting thing across every cause.
    public var count: Int { causes.reduce(0) { $0 + $1.count } }

    public var reasons: [AttentionReason] { causes.map(\.reason) }

    public func has(_ reason: AttentionReason) -> Bool { cause(reason) != nil }

    public func cause(_ reason: AttentionReason) -> AttentionCause? {
        causes.first { $0.reason == reason }
    }
}

/// One statement, whatever the project count: the attention signal for every project at once.
public struct ProjectAttentionStore: Sendable {
    let db: AppDatabase

    /// How long a shutdown delivery may sit unacknowledged before it is the human's problem.
    public static let shutdownGraceSeconds = ShutdownDeliveryStore.defaultGraceSeconds

    public init(_ db: AppDatabase) {
        self.db = db
    }

    public func all(
        now: Int64 = .nowMillis, graceSeconds: Int = shutdownGraceSeconds
    ) throws -> [ProjectAttention] {
        try db.reader.read { db in try Self.all(db, now: now, graceSeconds: graceSeconds) }
    }

    public func attention(
        projectId: String, now: Int64 = .nowMillis, graceSeconds: Int = shutdownGraceSeconds
    ) throws -> ProjectAttention? {
        try all(now: now, graceSeconds: graceSeconds).first { $0.id == projectId }
    }

    static func all(_ db: Database, now: Int64, graceSeconds: Int) throws -> [ProjectAttention] {
        let overdueAfter = Int64(graceSeconds) * 1000
        return try Row.fetchAll(db, sql: sql, arguments: [now, overdueAfter]).map(project(from:))
    }

    private static func project(from row: Row) -> ProjectAttention {
        var causes: [AttentionCause] = []
        func add(_ reason: AttentionReason, _ count: Int, detail: String? = nil) {
            guard count > 0 else { return }
            causes.append(AttentionCause(reason: reason, count: count, detail: detail))
        }
        add(.pendingApproval, row["approvals"])
        add(.blockedWorker, row["blocked_workers"], detail: row["blocked_title"])
        add(.strandedReports, row["stranded_reports"])
        add(.overdueShutdown, row["overdue_deliveries"])
        return ProjectAttention(
            id: row["id"],
            name: row["name"],
            causes: causes.sorted { $0.reason.severity < $1.reason.severity }
        )
    }

    /// Re-evaluates on every write to the tables it reads. It does not re-evaluate as the clock
    /// moves, so `overdueShutdown` appears on the next write after the grace period elapses, the
    /// same bound `ShutdownDeliveryStore.observeProgress` has; a caller that needs the deadline to
    /// tick on its own polls `all(now:)`.
    public func observeAll(
        graceSeconds: Int = shutdownGraceSeconds,
        clock: @escaping @Sendable () -> Int64 = { .nowMillis }
    ) -> ValueObservation<ValueReducers.Fetch<[ProjectAttention]>> {
        ValueObservation.tracking { db in
            try Self.all(db, now: clock(), graceSeconds: graceSeconds)
        }
    }

    public func observe(
        projectId: String,
        graceSeconds: Int = shutdownGraceSeconds,
        clock: @escaping @Sendable () -> Int64 = { .nowMillis }
    ) -> ValueObservation<ValueReducers.Fetch<ProjectAttention?>> {
        ValueObservation.tracking { db in
            try Self.all(db, now: clock(), graceSeconds: graceSeconds).first { $0.id == projectId }
        }
    }

    /// `blocked_title` is a bare column beside `MIN(updated_at)`: SQLite guarantees it comes from
    /// the row that produced the minimum, so the detail names the longest-blocked task.
    static let sql = """
        SELECT p.id AS id,
               p.name AS name,
               COALESCE(a.n, 0) AS approvals,
               COALESCE(b.n, 0) AS blocked_workers,
               b.title AS blocked_title,
               CASE WHEN COALESCE(o.n, 0) > 0 THEN 0 ELSE COALESCE(r.n, 0) END AS stranded_reports,
               COALESCE(s.n, 0) AS overdue_deliveries
        FROM project p
        LEFT JOIN (
            SELECT project_id, COUNT(*) AS n FROM approval
            WHERE resolved_at IS NULL GROUP BY project_id
        ) a ON a.project_id = p.id
        LEFT JOIN (
            SELECT project_id, COUNT(*) AS n, MIN(updated_at), title FROM task
            WHERE blocked = 1 AND archived_at IS NULL GROUP BY project_id
        ) b ON b.project_id = p.id
        LEFT JOIN (
            SELECT project_id, COUNT(*) AS n FROM agent_session
            WHERE role = '\(SessionRole.orchestrator.rawValue)'
              AND state IN (\(SessionStore.activeStatesSQL))
            GROUP BY project_id
        ) o ON o.project_id = p.id
        LEFT JOIN (
            SELECT project_id, COUNT(*) AS n FROM report
            WHERE consumed_at IS NULL GROUP BY project_id
        ) r ON r.project_id = p.id
        LEFT JOIN (
            SELECT so.project_id AS project_id, COUNT(*) AS n
            FROM shutdown_order so
            JOIN shutdown_delivery sd ON sd.order_id = so.id
            WHERE so.resolved_at IS NULL AND sd.acknowledged_at IS NULL AND ? - sd.ordered_at >= ?
            GROUP BY so.project_id
        ) s ON s.project_id = p.id
        ORDER BY p.name COLLATE NOCASE, p.created_at
        """
}
