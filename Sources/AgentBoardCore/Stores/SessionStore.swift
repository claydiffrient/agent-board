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

    /// Inserts the row a `/clear` fork runs under and hands it the human comments still queued for
    /// the session it forked from, which will never make another tool call (SPEC §7).
    public func insertFork(_ fork: AgentSession, from priorId: String) throws {
        try db.writer.write { db in
            try fork.insert(db)
            try db.execute(
                sql: "UPDATE comment_delivery SET session_id = ? WHERE session_id = ?",
                arguments: [fork.sessionId, priorId]
            )
        }
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

    /// The active worker session working `taskId`, if any. Two of these must never exist at once:
    /// both would be editing one worktree.
    public func activeHolder(taskId: String) throws -> AgentSession? {
        try db.reader.read { db in try Self.activeHolder(db, taskId: taskId) }
    }

    static func activeHolder(_ db: Database, taskId: String) throws -> AgentSession? {
        try AgentSession.fetchOne(
            db,
            sql: """
            SELECT * FROM agent_session
            WHERE task_id = ? AND role = 'worker' AND state IN (\(activeStatesSQL))
            ORDER BY started_at DESC LIMIT 1
            """,
            arguments: [taskId]
        )
    }

    /// The active session whose checkout is `path`, if any. A handed-off task keeps its worktree, so
    /// this is the check that stops a second agent being launched into a checkout someone still holds.
    public func activeHolder(worktreePath: String) throws -> AgentSession? {
        try db.reader.read { db in try Self.activeHolder(db, worktreePath: worktreePath) }
    }

    static func activeHolder(_ db: Database, worktreePath: String) throws -> AgentSession? {
        try AgentSession.fetchOne(
            db,
            sql: """
            SELECT * FROM agent_session
            WHERE worktree_path = ? AND state IN (\(activeStatesSQL))
            ORDER BY started_at DESC LIMIT 1
            """,
            arguments: [worktreePath]
        )
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

    /// `PreToolUse`: a call has started and is running. Starting one is itself activity, and the
    /// row keeps the *oldest* outstanding start, so a short parallel call cannot shorten the grace
    /// a long one is relying on.
    public func beginToolCall(_ sessionId: String, at: Int64, tool: String?) throws {
        try db.writer.write { db in
            try db.execute(
                sql: """
                UPDATE agent_session
                SET last_activity = ?, last_tool = COALESCE(?, last_tool),
                    tool_started_at = COALESCE(tool_started_at, ?),
                    tools_in_flight = tools_in_flight + 1
                WHERE session_id = ?
                """,
                arguments: [at, tool, at, sessionId]
            )
        }
    }

    /// `PostToolUse`: one call returned. The start only clears when the last outstanding call does;
    /// SQLite reads every `SET` expression off the pre-update row, so `<= 1` is that test.
    public func endToolCall(_ sessionId: String, at: Int64, tool: String?) throws {
        try db.writer.write { db in
            try db.execute(
                sql: """
                UPDATE agent_session
                SET last_activity = ?, last_tool = COALESCE(?, last_tool),
                    tool_started_at = CASE WHEN tools_in_flight <= 1 THEN NULL ELSE tool_started_at END,
                    tools_in_flight = MAX(tools_in_flight - 1, 0)
                WHERE session_id = ?
                """,
                arguments: [at, tool, sessionId]
            )
        }
    }

    /// A turn boundary. Nothing the model launched is still running once it has stopped, so this is
    /// what bounds a `PostToolUse` that never arrived to the turn it went missing in.
    public func clearToolCalls(_ sessionId: String) throws {
        try db.writer.write { db in
            try db.execute(
                sql: "UPDATE agent_session SET tool_started_at = NULL, tools_in_flight = 0 WHERE session_id = ?",
                arguments: [sessionId]
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

    /// Swaps the placeholder id a setup row was written under for the session id Claude actually
    /// issued, which every hook and transcript is keyed by. Nothing but a queued human comment may
    /// reference the placeholder yet: it is never handed to an agent, and the worker's grant binds
    /// after this returns. The prompt was composed before setup, so those comments move with the row.
    /// Throws if the row is gone or has left `setup` — a cap kill or a human stop got there first.
    public func promoteSetupSession(
        _ placeholderId: String, to sessionId: String, shortId: String?, state: SessionState = .starting
    ) throws -> AgentSession {
        try db.writer.write { db in
            guard let placeholder = try AgentSession.fetchOne(db, key: placeholderId) else {
                throw BoardError.sessionNotFound(placeholderId)
            }
            guard placeholder.state == .setup else {
                throw BoardError.sessionNotInSetup(placeholderId, placeholder.state)
            }
            let queued = try Int64.fetchAll(
                db, sql: "SELECT comment_id FROM comment_delivery WHERE session_id = ?", arguments: [placeholderId]
            )
            try db.execute(sql: "DELETE FROM agent_session WHERE session_id = ?", arguments: [placeholderId])
            var promoted = placeholder
            promoted.sessionId = sessionId
            promoted.shortId = shortId
            promoted.state = state
            try promoted.insert(db)
            for commentId in queued {
                try db.execute(
                    sql: "INSERT INTO comment_delivery (session_id, comment_id) VALUES (?, ?)",
                    arguments: [sessionId, commentId]
                )
            }
            return promoted
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

    /// Records that this session gave up waiting for another session's lock on `path`, so the
    /// `report_blocked` that follows knows to send the task back to `ready`.
    public func setBlockedOnPath(_ sessionId: String, _ path: String?) throws {
        try db.writer.write { db in
            try db.execute(
                sql: "UPDATE agent_session SET blocked_on_path = ? WHERE session_id = ?",
                arguments: [path, sessionId]
            )
        }
    }

    public func observe(projectId: String) -> ValueObservation<ValueReducers.Fetch<[AgentSession]>> {
        ValueObservation.tracking { db in
            try Self.all(db, projectId: projectId)
        }
    }

    /// The names a session goes by, for surfaces that hold a bare session id and need to say what it
    /// was — a listening port's owner, long after the session ended.
    ///
    /// Ended sessions answer exactly as live ones do; nothing deletes `agent_session` rows. An id
    /// with no row is simply absent from the result, which is what a caller renders as "no owner we
    /// can still name" rather than an error.
    public func names(of sessionIds: [String]) throws -> [String: SessionNames] {
        let wanted = Array(Set(sessionIds))
        guard !wanted.isEmpty else { return [:] }
        let placeholders = databaseQuestionMarks(count: wanted.count)
        let sql = """
            SELECT s.session_id AS session_id,
                   s.project_id AS project_id,
                   p.name AS project_name,
                   s.role AS role,
                   s.ended_at AS ended_at,
                   t.title AS task_title
            FROM agent_session s
            JOIN project p ON p.id = s.project_id
            LEFT JOIN task t ON t.id = s.task_id
            WHERE s.session_id IN (\(placeholders))
            """
        return try db.reader.read { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(wanted)).reduce(into: [:]) { result, row in
                let id: String = row["session_id"]
                let role: String = row["role"]
                result[id] = SessionNames(
                    sessionId: id,
                    projectId: row["project_id"],
                    projectName: row["project_name"],
                    taskTitle: row["task_title"],
                    role: SessionRole(rawValue: role) ?? .worker,
                    endedAtMillis: row["ended_at"]
                )
            }
        }
    }
}

public struct SessionNames: Sendable, Equatable {
    public let sessionId: String
    public let projectId: String
    public let projectName: String
    public let taskTitle: String?
    public let role: SessionRole
    public let endedAtMillis: Int64?

    public init(
        sessionId: String,
        projectId: String,
        projectName: String,
        taskTitle: String?,
        role: SessionRole,
        endedAtMillis: Int64?
    ) {
        self.sessionId = sessionId
        self.projectId = projectId
        self.projectName = projectName
        self.taskTitle = taskTitle
        self.role = role
        self.endedAtMillis = endedAtMillis
    }
}
