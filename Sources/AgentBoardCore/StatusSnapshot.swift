import Foundation
import GRDB

/// The roster agent a session runs as, and whether it runs as that agent's reviewer.
///
/// Reviewing is read from the scope of the first grant bound to the session, which is the scope it
/// was launched under: a resume after a stop re-issues a `worker` grant but leaves the first one on
/// record. A session with no grant bound yet (still setting up) falls back to the task naming this
/// agent as its reviewer. SPEC §10.
public struct SessionAgent: Sendable, Equatable {
    public var name: String
    public var isReviewing: Bool
    public var taskType: TaskType?

    public init(name: String, isReviewing: Bool, taskType: TaskType? = nil) {
        self.name = name
        self.isReviewing = isReviewing
        self.taskType = taskType
    }
}

/// Everything the Status page draws from the database, in one observation.
public struct StatusSnapshot: Sendable, Equatable {
    public var sessions: [AgentSession]
    /// Keyed by session id; a session with no roster agent is absent.
    public var agents: [String: SessionAgent]
    /// The Default row's routing. Nil unless the project's review level is `agent`.
    public var review: ReviewRouting?
    /// The type rows whose assignee differs from the Default row's, in `TaskType` order.
    public var typeReviews: [TypeReview]

    public struct TypeReview: Sendable, Equatable {
        public var type: TaskType
        public var routing: ReviewRouting

        public init(type: TaskType, routing: ReviewRouting) {
            self.type = type
            self.routing = routing
        }
    }

    public init(
        sessions: [AgentSession] = [], agents: [String: SessionAgent] = [:], review: ReviewRouting? = nil,
        typeReviews: [TypeReview] = []
    ) {
        self.sessions = sessions
        self.agents = agents
        self.review = review
        self.typeReviews = typeReviews
    }

    /// `reviewer · Rita · Code`, `worker · Rita`, or the bare role for a session with no roster agent.
    public func roleLabel(_ session: AgentSession) -> String {
        guard let agent = agents[session.sessionId] else { return session.role.rawValue }
        let label = "\(agent.isReviewing ? "reviewer" : session.role.rawValue) · \(agent.name)"
        guard agent.isReviewing, let type = agent.taskType else { return label }
        return "\(label) · \(type.label)"
    }

    static func fetch(_ db: Database, projectId: String) throws -> StatusSnapshot {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT s.session_id AS session_id,
                       r.name AS agent_name,
                       (SELECT g.scope FROM token_grant g WHERE g.session_id = s.session_id
                        ORDER BY g.created_at, g.rowid LIMIT 1) AS first_scope,
                       t.reviewer_agent_id = s.roster_agent_id AS task_names_it,
                       t.type AS task_type
                FROM agent_session s
                JOIN roster_agent r ON r.id = s.roster_agent_id
                LEFT JOIN task t ON t.id = s.task_id
                WHERE s.project_id = ?
                """,
            arguments: [projectId]
        )
        var agents: [String: SessionAgent] = [:]
        for row in rows {
            let scope: TokenScope? = row["first_scope"]
            let reviewing = scope.map { $0 == .reviewer } ?? (row["task_names_it"] as Bool? ?? false)
            agents[row["session_id"]] = SessionAgent(
                name: row["agent_name"], isReviewing: reviewing, taskType: row["task_type"]
            )
        }
        var review: ReviewRouting?
        var typeReviews: [TypeReview] = []
        if let settings = try Project.fetchOne(db, key: projectId)?.settings, settings.reviewLevel == .agent {
            review = try ReviewPolicy.agentRouting(db, projectId: projectId, type: nil)
            let table = settings.reviewRouting
            typeReviews = try TaskType.allCases
                .filter { type in table.typeAssignees[type].map { $0 != table.defaultAssignee } ?? false }
                .map { TypeReview(type: $0, routing: try ReviewPolicy.agentRouting(db, projectId: projectId, type: $0)) }
        }
        return StatusSnapshot(
            sessions: try SessionStore.all(db, projectId: projectId),
            agents: agents,
            review: review,
            typeReviews: typeReviews
        )
    }
}

extension SessionStore {
    public func observeStatus(projectId: String) -> ValueObservation<ValueReducers.Fetch<StatusSnapshot>> {
        ValueObservation.tracking { db in
            try StatusSnapshot.fetch(db, projectId: projectId)
        }
    }
}
