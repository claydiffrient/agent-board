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

    public init(id: String, name: String, running: Int, review: Int, ready: Int) {
        self.id = id
        self.name = name
        self.running = running
        self.review = review
        self.ready = ready
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

    public init(projects: [ProjectGlance], workingSessions: Int, tasksInReview: Int) {
        self.projects = projects
        self.workingSessions = workingSessions
        self.tasksInReview = tasksInReview
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
        let working = try Int.fetchOne(db, sql: workingSessionsSQL) ?? 0
        return GlanceSummary(
            projects: projects,
            workingSessions: working,
            tasksInReview: projects.reduce(0) { $0 + $1.review }
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
               \(countOf(.ready)) AS ready
        FROM project p
        LEFT JOIN task t ON t.project_id = p.id AND t.archived_at IS NULL
        GROUP BY p.id
        ORDER BY p.name COLLATE NOCASE, p.created_at
        """

    static let workingSessionsSQL = """
        SELECT COUNT(*) FROM agent_session
        WHERE role = '\(SessionRole.worker.rawValue)' AND state IN (\(SessionStore.activeStatesSQL))
        """

    /// A project with no matching rows sums to NULL through the outer join, not 0.
    private static func countOf(_ column: TaskColumn) -> String {
        "COALESCE(SUM(t.column_name = '\(column.rawValue)'), 0)"
    }
}
