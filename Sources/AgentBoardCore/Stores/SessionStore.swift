import Foundation
import GRDB

public struct SessionStore: Sendable {
    let db: AppDatabase

    public init(_ db: AppDatabase) {
        self.db = db
    }

    public func insert(_ session: AgentSession) throws {
        try db.writer.write { db in try session.insert(db) }
    }

    public func get(_ sessionId: String) throws -> AgentSession? {
        try db.reader.read { db in try AgentSession.fetchOne(db, key: sessionId) }
    }

    public func forTask(_ taskId: String) throws -> [AgentSession] {
        try db.reader.read { db in
            try AgentSession.fetchAll(
                db,
                sql: "SELECT * FROM agent_session WHERE task_id = ? ORDER BY started_at DESC, attempt DESC",
                arguments: [taskId]
            )
        }
    }

    public func orchestrator(projectId: String) throws -> AgentSession? {
        try db.reader.read { db in
            try AgentSession.fetchOne(
                db,
                sql: "SELECT * FROM agent_session WHERE project_id = ? AND role = 'orchestrator' ORDER BY started_at DESC LIMIT 1",
                arguments: [projectId]
            )
        }
    }

    public func active(projectId: String) throws -> [AgentSession] {
        try db.reader.read { db in
            try Self.active(db, projectId: projectId)
        }
    }

    static func active(_ db: Database, projectId: String) throws -> [AgentSession] {
        try AgentSession.fetchAll(
            db,
            sql: "SELECT * FROM agent_session WHERE project_id = ? AND state IN (\(activeStatesSQL)) ORDER BY started_at",
            arguments: [projectId]
        )
    }

    static var activeStatesSQL: String {
        SessionState.activeStates.map { "'\($0.rawValue)'" }.joined(separator: ", ")
    }

    public func all(projectId: String) throws -> [AgentSession] {
        try db.reader.read { db in
            try Self.all(db, projectId: projectId)
        }
    }

    static func all(_ db: Database, projectId: String) throws -> [AgentSession] {
        try AgentSession.fetchAll(
            db,
            sql: "SELECT * FROM agent_session WHERE project_id = ? ORDER BY started_at DESC",
            arguments: [projectId]
        )
    }

    public func setState(_ sessionId: String, _ state: SessionState, endedAt: Int64? = nil) throws {
        try db.writer.write { db in
            try Self.setState(db, sessionId, state, endedAt: endedAt)
        }
    }

    /// A resumed session restarts its wall clock; the previous run's end and stop reason are cleared.
    public func markResumed(_ sessionId: String, at: Int64 = .nowMillis) throws {
        try db.writer.write { db in
            try db.execute(
                sql: "UPDATE agent_session SET state = 'running', started_at = ?, last_activity = ?, ended_at = NULL, stop_reason = NULL WHERE session_id = ?",
                arguments: [at, at, sessionId]
            )
        }
    }

    static func setState(_ db: Database, _ sessionId: String, _ state: SessionState, endedAt: Int64?) throws {
        if let endedAt {
            try db.execute(
                sql: "UPDATE agent_session SET state = ?, ended_at = ? WHERE session_id = ?",
                arguments: [state, endedAt, sessionId]
            )
        } else {
            try db.execute(
                sql: "UPDATE agent_session SET state = ? WHERE session_id = ?",
                arguments: [state, sessionId]
            )
        }
    }

    public func recordActivity(_ sessionId: String, at: Int64, lastTool: String?) throws {
        try db.writer.write { db in
            try db.execute(
                sql: "UPDATE agent_session SET last_activity = ?, last_tool = COALESCE(?, last_tool) WHERE session_id = ?",
                arguments: [at, lastTool, sessionId]
            )
        }
    }

    public func updateSpend(
        _ sessionId: String, tokensIn: Int, tokensOut: Int, cacheRead: Int, cacheWrite: Int,
        estCostUSD: Double, model: String?
    ) throws {
        try db.writer.write { db in
            try db.execute(
                sql: """
                UPDATE agent_session
                SET tokens_in = ?, tokens_out = ?, cache_read = ?, cache_write = ?, est_cost_usd = ?,
                    model = COALESCE(?, model)
                WHERE session_id = ?
                """,
                arguments: [tokensIn, tokensOut, cacheRead, cacheWrite, estCostUSD, model, sessionId]
            )
        }
    }

    public func setTranscriptPath(_ sessionId: String, _ path: String) throws {
        try db.writer.write { db in
            try db.execute(
                sql: "UPDATE agent_session SET transcript_path = ? WHERE session_id = ?",
                arguments: [path, sessionId]
            )
        }
    }

    public func setShortId(_ sessionId: String, _ shortId: String) throws {
        try db.writer.write { db in
            try db.execute(
                sql: "UPDATE agent_session SET short_id = ? WHERE session_id = ?",
                arguments: [shortId, sessionId]
            )
        }
    }

    public func setStopReason(_ sessionId: String, _ reason: String?) throws {
        try db.writer.write { db in
            try Self.setStopReason(db, sessionId, reason)
        }
    }

    static func setStopReason(_ db: Database, _ sessionId: String, _ reason: String?) throws {
        try db.execute(
            sql: "UPDATE agent_session SET stop_reason = ? WHERE session_id = ?",
            arguments: [reason, sessionId]
        )
    }

    public func observe(projectId: String) -> ValueObservation<ValueReducers.Fetch<[AgentSession]>> {
        ValueObservation.tracking { db in
            try Self.all(db, projectId: projectId)
        }
    }
}
