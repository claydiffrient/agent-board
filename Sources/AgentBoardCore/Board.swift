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

    @discardableResult
    public func accept(taskId: String) throws -> [String] {
        try db.writer.write { db in
            let task = try Self.requireTask(db, taskId)
            try TaskStore.setBlocked(db, taskId, false, reason: nil)
            try TaskStore.setFailed(db, taskId, false, reason: nil)
            try TaskStore.move(db, taskId, to: .done, before: nil)
            return try Self.newlyReady(db, projectId: task.projectId)
        }
    }

    public func reopen(taskId: String) throws {
        try db.writer.write { db in
            _ = try Self.requireTask(db, taskId)
            try TaskStore.setBlocked(db, taskId, false, reason: nil)
            try TaskStore.setFailed(db, taskId, false, reason: nil)
            try TaskStore.move(db, taskId, to: .ready, before: nil)
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
            return try Self.newlyReady(db, projectId: task.projectId)
        }
    }

    static func requireTask(_ db: Database, _ taskId: String) throws -> Task {
        guard let task = try Task.fetchOne(db, key: taskId) else {
            throw BoardError.taskNotFound(taskId)
        }
        return task
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
