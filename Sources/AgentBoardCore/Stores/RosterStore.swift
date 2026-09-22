import Foundation
import GRDB

public struct RosterStore: Sendable {
    let db: AppDatabase

    public init(_ db: AppDatabase) {
        self.db = db
    }

    @discardableResult
    public func create(
        name: String, role: String, systemPrompt: String,
        model: String? = nil, disallowedTools: [String] = [], enabled: Bool = true
    ) throws -> RosterAgent {
        let now = Int64.nowMillis
        let agent = RosterAgent(
            id: RosterAgent.newId(), name: name, role: role, systemPrompt: systemPrompt,
            model: model, disallowedTools: disallowedTools, enabled: enabled, createdAt: now, updatedAt: now
        )
        try db.writer.write { db in try agent.insert(db) }
        return agent
    }

    public func get(_ id: String) throws -> RosterAgent? {
        try db.reader.read { db in try RosterAgent.fetchOne(db, key: id) }
    }

    public func list() throws -> [RosterAgent] {
        try db.reader.read { db in try Self.list(db) }
    }

    static func list(_ db: Database) throws -> [RosterAgent] {
        try RosterAgent.fetchAll(
            db,
            sql: "SELECT * FROM roster_agent ORDER BY name COLLATE NOCASE, created_at"
        )
    }

    public func update(_ agent: RosterAgent) throws {
        var agent = agent
        agent.updatedAt = .nowMillis
        try db.writer.write { db in
            guard try RosterAgent.exists(db, key: agent.id) else {
                throw BoardError.rosterAgentNotFound(agent.id)
            }
            try agent.update(db)
        }
    }

    public func setEnabled(_ id: String, _ enabled: Bool) throws {
        try db.writer.write { db in
            guard try RosterAgent.exists(db, key: id) else {
                throw BoardError.rosterAgentNotFound(id)
            }
            try db.execute(
                sql: "UPDATE roster_agent SET enabled = ?, updated_at = ? WHERE id = ?",
                arguments: [enabled, Int64.nowMillis, id]
            )
        }
    }

    /// Removes the agent from the roster and from every project that had opted in. Nothing else
    /// is touched: the tasks it worked, its sessions, and the progress rows naming it all survive.
    public func delete(_ id: String) throws {
        try db.writer.write { db in
            try db.execute(sql: "DELETE FROM project_roster_agent WHERE roster_agent_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM roster_agent WHERE id = ?", arguments: [id])
        }
    }

    /// Every agent the project has opted into, disabled ones included, in the project's own order.
    public func agents(forProject projectId: String) throws -> [RosterAgent] {
        try db.reader.read { db in try Self.agents(db, forProject: projectId, enabledOnly: false) }
    }

    /// The subset the project can actually spawn: opted in *and* enabled in the roster.
    public func usableAgents(forProject projectId: String) throws -> [RosterAgent] {
        try db.reader.read { db in try Self.agents(db, forProject: projectId, enabledOnly: true) }
    }

    /// One agent, but only if the project may actually be given work on it. Nil is the single
    /// refusal for "no such agent", "disabled" and "not opted into" — the caller says which.
    public func usableAgent(_ id: String, forProject projectId: String) throws -> RosterAgent? {
        try usableAgents(forProject: projectId).first { $0.id == id }
    }

    static func agents(_ db: Database, forProject projectId: String, enabledOnly: Bool) throws -> [RosterAgent] {
        try RosterAgent.fetchAll(
            db,
            sql: """
            SELECT a.* FROM roster_agent a
            JOIN project_roster_agent p ON p.roster_agent_id = a.id
            WHERE p.project_id = ?\(enabledOnly ? " AND a.enabled = 1" : "")
            ORDER BY p.ordering, a.created_at
            """,
            arguments: [projectId]
        )
    }

    /// Opts the project into the agent, appended last in the project's order. Re-enabling an agent
    /// the project already uses keeps its existing position.
    public func enable(agentId: String, forProject projectId: String) throws {
        try db.writer.write { db in
            guard try RosterAgent.exists(db, key: agentId) else {
                throw BoardError.rosterAgentNotFound(agentId)
            }
            guard try Project.exists(db, key: projectId) else {
                throw BoardError.projectNotFound(projectId)
            }
            let existing = try Double.fetchOne(
                db,
                sql: "SELECT ordering FROM project_roster_agent WHERE project_id = ? AND roster_agent_id = ?",
                arguments: [projectId, agentId]
            )
            guard existing == nil else { return }
            let max = try Double.fetchOne(
                db,
                sql: "SELECT MAX(ordering) FROM project_roster_agent WHERE project_id = ?",
                arguments: [projectId]
            )
            try ProjectRosterAgent(
                projectId: projectId, rosterAgentId: agentId, ordering: (max ?? 0) + 1
            ).insert(db)
        }
    }

    /// Opts the project back out. The agent itself stays in the roster, as does every other project's
    /// use of it.
    public func disable(agentId: String, forProject projectId: String) throws {
        try db.writer.write { db in
            try db.execute(
                sql: "DELETE FROM project_roster_agent WHERE project_id = ? AND roster_agent_id = ?",
                arguments: [projectId, agentId]
            )
        }
    }

    /// Rewrites the project's preference order. Ids the project has not opted into are ignored;
    /// ones it uses but that are absent from `agentIds` keep their relative order after the listed ones.
    public func setOrder(forProject projectId: String, agentIds: [String]) throws {
        try db.writer.write { db in
            let current = try String.fetchAll(
                db,
                sql: "SELECT roster_agent_id FROM project_roster_agent WHERE project_id = ? ORDER BY ordering",
                arguments: [projectId]
            )
            let listed = agentIds.filter(current.contains)
            let ordered = listed + current.filter { !listed.contains($0) }
            for (index, id) in ordered.enumerated() {
                try db.execute(
                    sql: "UPDATE project_roster_agent SET ordering = ? WHERE project_id = ? AND roster_agent_id = ?",
                    arguments: [Double(index + 1), projectId, id]
                )
            }
        }
    }

    /// Every rostered agent holding a live session right now, across every project. A session that
    /// has ended must not appear: the roster screen badges these and its delete guard refuses on
    /// them, and refusing on a finished session would strand the agent permanently.
    public func assignments() throws -> [RosterAssignment] {
        try db.reader.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT s.roster_agent_id AS agent_id, t.id AS task_id, t.title AS task_title,
                       p.name AS project_name
                FROM agent_session s
                JOIN task t ON t.id = s.task_id
                JOIN project p ON p.id = s.project_id
                WHERE s.roster_agent_id IS NOT NULL
                  AND s.state IN (\(SessionStore.activeStatesSQL))
                ORDER BY s.started_at
                """
            ).map {
                RosterAssignment(
                    agentId: $0["agent_id"], taskId: $0["task_id"],
                    taskTitle: $0["task_title"], projectName: $0["project_name"]
                )
            }
        }
    }

    public func observe() -> ValueObservation<ValueReducers.Fetch<[RosterAgent]>> {
        ValueObservation.tracking { db in try Self.list(db) }
    }

    public func observe(projectId: String) -> ValueObservation<ValueReducers.Fetch<[RosterAgent]>> {
        ValueObservation.tracking { db in
            try Self.agents(db, forProject: projectId, enabledOnly: false)
        }
    }
}
