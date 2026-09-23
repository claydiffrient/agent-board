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

    public init(name: String, isReviewing: Bool) {
        self.name = name
        self.isReviewing = isReviewing
    }
}

/// Everything the Status page draws from the database, in one observation.
public struct StatusSnapshot: Sendable, Equatable {
    public var sessions: [AgentSession]
    /// Keyed by session id; a session with no roster agent is absent.
    public var agents: [String: SessionAgent]
    /// Nil unless the project's review level is `agent`.
    public var review: ReviewRouting?

    public init(sessions: [AgentSession] = [], agents: [String: SessionAgent] = [:], review: ReviewRouting? = nil) {
        self.sessions = sessions
        self.agents = agents
        self.review = review
    }

    /// `reviewer · Rita`, `worker · Rita`, or the bare role for a session with no roster agent.
    public func roleLabel(_ session: AgentSession) -> String {
        guard let agent = agents[session.sessionId] else { return session.role.rawValue }
        return "\(agent.isReviewing ? "reviewer" : session.role.rawValue) · \(agent.name)"
    }

    static func fetch(_ db: Database, projectId: String) throws -> StatusSnapshot {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT s.session_id AS session_id,
                       r.name AS agent_name,
                       (SELECT g.scope FROM token_grant g WHERE g.session_id = s.session_id
                        ORDER BY g.created_at, g.rowid LIMIT 1) AS first_scope,
                       t.reviewer_agent_id = s.roster_agent_id AS task_names_it
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
            agents[row["session_id"]] = SessionAgent(name: row["agent_name"], isReviewing: reviewing)
        }
        let level = try Project.fetchOne(db, key: projectId)?.settings.reviewLevel
        return StatusSnapshot(
            sessions: try SessionStore.all(db, projectId: projectId),
            agents: agents,
            review: level == .agent ? try ReviewPolicy.agentRouting(db, projectId: projectId) : nil
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
