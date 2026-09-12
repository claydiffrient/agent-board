import Foundation
import GRDB

public enum CapDecision: Sendable, Equatable {
    case allowed
    case refused(reason: String)

    public var isAllowed: Bool { self == .allowed }
}

public struct CapCheck: Sendable {
    let db: AppDatabase

    public init(_ db: AppDatabase) {
        self.db = db
    }

    public func canSpawn(projectId: String) throws -> CapDecision {
        try db.reader.read { db in
            try Self.canSpawn(db, projectId: projectId)
        }
    }

    static func canSpawn(_ db: Database, projectId: String) throws -> CapDecision {
        guard let project = try Project.fetchOne(db, key: projectId) else {
            throw BoardError.projectNotFound(projectId)
        }
        let caps = project.settings.caps
        let activeWorkers = try Int.fetchOne(
            db,
            sql: """
            SELECT COUNT(*) FROM agent_session
            WHERE project_id = ? AND role = 'worker' AND state IN (\(SessionStore.activeStatesSQL))
            """,
            arguments: [projectId]
        ) ?? 0
        if activeWorkers >= caps.maxConcurrentWorkers {
            return .refused(reason: "\(activeWorkers) of \(caps.maxConcurrentWorkers) concurrent workers already running")
        }
        if let ceiling = caps.sessionCeiling {
            let total = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM agent_session WHERE project_id = ?",
                arguments: [projectId]
            ) ?? 0
            if total >= ceiling {
                return .refused(reason: "project session ceiling of \(ceiling) reached (\(total) sessions)")
            }
        }
        return .allowed
    }
}

/// Why Agent Board, rather than the worker itself, is ending a session.
public enum SessionTermination: Sendable, Equatable {
    case capBreach(String)
    case stoppedByHuman
    /// `reconcile` found the process gone without Agent Board having stopped it.
    case vanished

    var sessionState: SessionState {
        switch self {
        case .capBreach: return .failed
        case .stoppedByHuman, .vanished: return .stopped
        }
    }

    var flagsTaskFailed: Bool {
        switch self {
        case .capBreach, .vanished: return true
        case .stoppedByHuman: return false
        }
    }

    var reason: String {
        switch self {
        case .capBreach(let breach): return breach
        case .stoppedByHuman: return "stopped from Agent Board by a human"
        case .vanished: return "the session is no longer running and Agent Board did not stop it"
        }
    }
}

public enum SpawnGate: Sendable, Equatable {
    case proceed
    case approvalPending(Approval)
    case refused(reason: String)
}

public struct Board: Sendable {
    let db: AppDatabase

    public init(_ db: AppDatabase) {
        self.db = db
    }

    public func canSpawn(projectId: String) throws -> CapDecision {
        try CapCheck(db).canSpawn(projectId: projectId)
    }

    /// Orchestrator-initiated spawn: only `ready` tasks; caps via CapCheck; autonomy off yields a pending approval (one per task).
    public func requestSpawn(taskId: String, requestedBy: String) throws -> SpawnGate {
        try db.writer.write { db in
            guard let task = try Task.fetchOne(db, key: taskId) else {
                return .refused(reason: "task \(taskId) not found")
            }
            guard task.column == .ready else {
                return .refused(reason: "task \(taskId) is in \(task.column.rawValue), only ready tasks can be spawned")
            }
            if case .refused(let reason) = try CapCheck.canSpawn(db, projectId: task.projectId) {
                return .refused(reason: reason)
            }
            guard let project = try Project.fetchOne(db, key: task.projectId) else {
                throw BoardError.projectNotFound(task.projectId)
            }
            if project.settings.autonomyEnabled {
                return .proceed
            }
            if let existing = try ApprovalStore.pendingSpawn(db, taskId: taskId) {
                return .approvalPending(existing)
            }
            let approval = try ApprovalStore.insert(
                db, projectId: task.projectId, kind: .spawn, taskId: taskId, epicId: task.epicId,
                requestedBy: requestedBy, reason: nil
            )
            return .approvalPending(approval)
        }
    }

    /// Resolves the approval and queues a `decision` report so the orchestrator learns the outcome on its next pull.
    @discardableResult
    public func resolveApproval(_ id: String, approved: Bool, by: String, reason: String? = nil) throws -> Approval {
        try db.writer.write { db in
            let approval = try ApprovalStore.resolve(db, id, approved ? .approved : .denied)
            var body = "\(approval.kind.rawValue) \(approved ? "approved" : "denied")"
            if let taskId = approval.taskId {
                body += " for task \(taskId)"
                if let task = try Task.fetchOne(db, key: taskId) {
                    body += " (\(task.title))"
                }
            } else if let epicId = approval.epicId {
                body += " for epic \(epicId)"
            }
            if let reason, !reason.isEmpty {
                body += ": \(reason)"
            }
            body += "\n\nResolved by: \(by)"
            _ = try ReportStore.insert(
                db, projectId: approval.projectId, taskId: approval.taskId, sessionId: nil, kind: .decision, body: body
            )
            return approval
        }
    }

    @discardableResult
    public func assign(taskId: String, session: AgentSession) throws -> AgentSession {
        try db.writer.write { db in
            guard let task = try Task.fetchOne(db, key: taskId) else {
                throw BoardError.taskNotFound(taskId)
            }
            let previousAttempts = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM agent_session WHERE task_id = ?",
                arguments: [taskId]
            ) ?? 0
            var session = session
            session.taskId = taskId
            session.projectId = task.projectId
            session.role = .worker
            session.state = .starting
            session.attempt = previousAttempts + 1
            try session.insert(db)
            try TaskStore.setBlocked(db, taskId, false, reason: nil)
            try TaskStore.setFailed(db, taskId, false, reason: nil)
            try TaskStore.move(db, taskId, to: .running, before: nil)
            return session
        }
    }

    @discardableResult
    public func complete(taskId: String, sessionId: String, summary: String) throws -> Report {
        try db.writer.write { db in
            let task = try Self.requireTask(db, taskId)
            let report = try ReportStore.insert(
                db, projectId: task.projectId, taskId: taskId, sessionId: sessionId, kind: .complete, body: summary
            )
            try TaskStore.setBlocked(db, taskId, false, reason: nil)
            try TaskStore.move(db, taskId, to: .review, before: nil)
            try SessionStore.setState(db, sessionId, .completed, endedAt: .nowMillis)
            return report
        }
    }

    @discardableResult
    public func fail(taskId: String, sessionId: String, reason: String) throws -> Report {
        try db.writer.write { db in
            let task = try Self.requireTask(db, taskId)
            let report = try ReportStore.insert(
                db, projectId: task.projectId, taskId: taskId, sessionId: sessionId, kind: .failed, body: reason
            )
            try TaskStore.setBlocked(db, taskId, false, reason: nil)
            try TaskStore.setFailed(db, taskId, true, reason: reason)
            try SessionStore.setState(db, sessionId, .failed, endedAt: .nowMillis)
            return report
        }
    }

    @discardableResult
    public func block(taskId: String, sessionId: String, reason: String) throws -> Report {
        try db.writer.write { db in
            let task = try Self.requireTask(db, taskId)
            let report = try ReportStore.insert(
                db, projectId: task.projectId, taskId: taskId, sessionId: sessionId, kind: .blocked, body: reason
            )
            try TaskStore.setBlocked(db, taskId, true, reason: reason)
            try SessionStore.setState(db, sessionId, .blocked, endedAt: nil)
            return report
        }
    }

    public func unblock(taskId: String, sessionId: String) throws {
        try db.writer.write { db in
            _ = try Self.requireTask(db, taskId)
            try TaskStore.setBlocked(db, taskId, false, reason: nil)
            try db.execute(
                sql: "UPDATE agent_session SET state = 'running' WHERE session_id = ? AND state = 'blocked'",
                arguments: [sessionId]
            )
        }
    }

    /// Accepts into `done` and queues a `decision` report; the newly-ready ids are the orchestrator's
    /// only signal that the dependency graph moved.
    @discardableResult
    public func accept(taskId: String) throws -> [String] {
        try db.writer.write { db in
            let task = try Self.requireTask(db, taskId)
            try TaskStore.setBlocked(db, taskId, false, reason: nil)
            try TaskStore.setFailed(db, taskId, false, reason: nil)
            try TaskStore.move(db, taskId, to: .done, before: nil)
            let ready = try Self.newlyReady(db, projectId: task.projectId)
            var body = "Task \(taskId) (\(task.title)) was accepted into done by a human."
            body += "\n\n" + (try Self.describeNewlyReady(db, ready))
            _ = try ReportStore.insert(
                db, projectId: task.projectId, taskId: taskId, sessionId: nil, kind: .decision, body: body
            )
            return ready
        }
    }

    @discardableResult
    public func reopen(taskId: String) throws -> Report {
        try db.writer.write { db in
            let task = try Self.requireTask(db, taskId)
            try TaskStore.setBlocked(db, taskId, false, reason: nil)
            try TaskStore.setFailed(db, taskId, false, reason: nil)
            try TaskStore.move(db, taskId, to: .ready, before: nil)
            return try ReportStore.insert(
                db, projectId: task.projectId, taskId: taskId, sessionId: nil, kind: .decision,
                body: "Task \(taskId) (\(task.title)) was reopened by a human and is back in ready."
            )
        }
    }

    /// Deletes the task and leaves a `decision` report behind, so an orchestrator holding the id
    /// learns it is gone rather than dispatching it.
    @discardableResult
    public func discard(taskId: String) throws -> Report {
        try db.writer.write { db in
            let task = try Self.requireTask(db, taskId)
            let report = try ReportStore.insert(
                db, projectId: task.projectId, taskId: nil, sessionId: nil, kind: .decision,
                body: "Task \(taskId) (\(task.title)) was discarded by a human and removed from the board. Do not dispatch it."
            )
            try TaskStore.delete(db, taskId)
            return report
        }
    }

    /// Ends a worker session that will not report for itself and queues a `failed` report, so the
    /// orchestrator stops believing the worker is running. A task stranded in `running` returns to `ready`.
    @discardableResult
    public func terminate(sessionId: String, cause: SessionTermination) throws -> Report? {
        try db.writer.write { db in
            guard let session = try AgentSession.fetchOne(db, key: sessionId), session.state.isActive else {
                return nil
            }
            let reason = cause.reason
            try SessionStore.setState(db, sessionId, cause.sessionState, endedAt: .nowMillis)
            try SessionStore.setStopReason(db, sessionId, reason)
            guard session.role == .worker, let taskId = session.taskId,
                  let task = try Task.fetchOne(db, key: taskId)
            else { return nil }

            try TaskStore.setBlocked(db, taskId, false, reason: nil)
            if cause.flagsTaskFailed {
                try TaskStore.setFailed(db, taskId, true, reason: reason)
            }
            let stranded = task.column == .running
            if stranded {
                try TaskStore.move(db, taskId, to: .ready, before: nil)
            }
            let body = [
                "Worker session ended without reporting: \(reason)",
                "Task: \(taskId) (\(task.title))",
                "Session: \(sessionId) (attempt \(session.attempt))",
                stranded
                    ? "The task is back in ready; dispatch it again if you want it retried."
                    : "The task stayed in \(task.column.rawValue).",
            ].joined(separator: "\n")
            return try ReportStore.insert(
                db, projectId: session.projectId, taskId: taskId, sessionId: sessionId, kind: .failed, body: body
            )
        }
    }

    @discardableResult
    public func propose(projectId: String, title: String, body: String?, rationale: String?, sessionId: String?) throws -> Task {
        try db.writer.write { db in
            let task = try TaskStore.insert(
                db, projectId: projectId, title: title, body: body, acceptance: nil, priority: nil,
                column: .proposed, origin: .workerProposal, epicId: nil
            )
            var lines = ["Proposed task: \(title)", "Task id: \(task.id)"]
            if let body, !body.isEmpty { lines.append(body) }
            if let rationale, !rationale.isEmpty { lines.append("Rationale: \(rationale)") }
            _ = try ReportStore.insert(
                db, projectId: projectId, taskId: task.id, sessionId: sessionId, kind: .proposal,
                body: lines.joined(separator: "\n\n")
            )
            return task
        }
    }

    @discardableResult
    public func promote(taskId: String) throws -> [String] {
        try db.writer.write { db in
            let task = try Self.requireTask(db, taskId)
            guard task.column == .proposed else {
                throw BoardError.invalidTransition(taskId: taskId, from: task.column, to: .backlog)
            }
            try TaskStore.move(db, taskId, to: .backlog, before: nil)
            let ready = try Self.newlyReady(db, projectId: task.projectId)
            let landed = try Task.fetchOne(db, key: taskId)?.column ?? .backlog
            var body = "Proposal \(taskId) (\(task.title)) was promoted to \(landed.rawValue)."
            body += "\n\n" + (try Self.describeNewlyReady(db, ready))
            _ = try ReportStore.insert(
                db, projectId: task.projectId, taskId: taskId, sessionId: nil, kind: .decision, body: body
            )
            return ready
        }
    }

    static func requireTask(_ db: Database, _ taskId: String) throws -> Task {
        guard let task = try Task.fetchOne(db, key: taskId) else {
            throw BoardError.taskNotFound(taskId)
        }
        return task
    }

    static func describeNewlyReady(_ db: Database, _ ids: [String]) throws -> String {
        guard !ids.isEmpty else { return "No other task became ready as a result." }
        let described = try ids.map { id -> String in
            guard let title = try Task.fetchOne(db, key: id)?.title else { return id }
            return "\(id) (\(title))"
        }
        return "Now ready to dispatch:\n" + described.map { "- \($0)" }.joined(separator: "\n")
    }

    static func newlyReady(_ db: Database, projectId: String) throws -> [String] {
        let changed = try TaskStore.refreshReadiness(db, projectId: projectId)
        guard !changed.isEmpty else { return [] }
        let placeholders = databaseQuestionMarks(count: changed.count)
        return try String.fetchAll(
            db,
            sql: "SELECT id FROM task WHERE column_name = 'ready' AND id IN (\(placeholders)) ORDER BY ordering",
            arguments: StatementArguments(changed)
        )
    }
}
