import Foundation
import GRDB

/// One project's card on the cross-project status page: what is moving, what is waiting on a human,
/// and what is queued. Archived tasks are not counted.
public struct ProjectGlance: Codable, FetchableRecord, Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var running: Int
    public var review: Int
    public var ready: Int
    /// Every session's estimated spend on this project, ended ones included.
    public var spendUSD: Double

    public init(id: String, name: String, running: Int, review: Int, ready: Int, spendUSD: Double = 0) {
        self.id = id
        self.name = name
        self.running = running
        self.review = review
        self.ready = ready
        self.spendUSD = spendUSD
    }
}

public struct GlanceSummary: Sendable, Equatable {
    /// Every registered project, including ones with no tasks at all, ordered as `ProjectStore.list`
    /// orders them.
    public var projects: [ProjectGlance]

    /// Worker sessions in an active state, across every project.
    ///
    /// `setup` counts: the state holds a concurrency slot and resolves into a running agent, so
    /// excluding it would report "nothing is happening" while worktrees are being prepared, and
    /// would disagree with the cap the human sees in `CapCheck`. The orchestrator does not count —
    /// it is the session the human is talking to, not work being done for them, which is the same
    /// line `CapCheck` draws with `role = 'worker'`.
    public var workingSessions: Int

    public var tasksInReview: Int

    /// Every Coordinator session's estimated spend (SPEC §8.2); it has no cap.
    public var coordinatorSpendUSD: Double

    public init(projects: [ProjectGlance], workingSessions: Int, tasksInReview: Int, coordinatorSpendUSD: Double = 0) {
        self.projects = projects
        self.workingSessions = workingSessions
        self.tasksInReview = tasksInReview
        self.coordinatorSpendUSD = coordinatorSpendUSD
    }

    public static let empty = GlanceSummary(projects: [], workingSessions: 0, tasksInReview: 0)
}

/// The whole board in one read: per-project task counts plus cross-project totals, for the page
/// shown when no project is selected. Two statements, whatever the project count.
public struct GlanceStore: Sendable {
    let db: AppDatabase

    public init(_ db: AppDatabase) {
        self.db = db
    }

    public func summary() throws -> GlanceSummary {
        try db.reader.read { db in try Self.summary(db) }
    }

    static func summary(_ db: Database) throws -> GlanceSummary {
        let projects = try ProjectGlance.fetchAll(db, sql: projectCountsSQL)
        let totals = try Row.fetchOne(db, sql: totalsSQL)
        return GlanceSummary(
            projects: projects,
            workingSessions: totals?["working"] ?? 0,
            tasksInReview: projects.reduce(0) { $0 + $1.review },
            coordinatorSpendUSD: totals?["coordinator_spend"] ?? 0
        )
    }

    public func observe() -> ValueObservation<ValueReducers.Fetch<GlanceSummary>> {
        ValueObservation.tracking { db in try Self.summary(db) }
    }

    static let projectCountsSQL = """
        SELECT p.id AS id,
               p.name AS name,
               \(countOf(.running)) AS running,
               \(countOf(.review)) AS review,
               \(countOf(.ready)) AS ready,
               (SELECT COALESCE(SUM(s.est_cost_usd), 0) FROM agent_session s WHERE s.project_id = p.id) AS spendUSD
        FROM project p
        LEFT JOIN task t ON t.project_id = p.id AND t.archived_at IS NULL
        GROUP BY p.id
        ORDER BY p.name COLLATE NOCASE, p.created_at
        """

    static let totalsSQL = """
        SELECT (SELECT COUNT(*) FROM agent_session
                WHERE role = '\(SessionRole.worker.rawValue)' AND state IN (\(SessionStore.activeStatesSQL))) AS working,
               (SELECT COALESCE(SUM(est_cost_usd), 0) FROM agent_session
                WHERE role = '\(SessionRole.coordinator.rawValue)') AS coordinator_spend
        """

    /// A project with no matching rows sums to NULL through the outer join, not 0.
    private static func countOf(_ column: TaskColumn) -> String {
        "COALESCE(SUM(t.column_name = '\(column.rawValue)'), 0)"
    }
}
