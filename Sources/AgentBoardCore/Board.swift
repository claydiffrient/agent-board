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
    /// Preparing the worktree failed after `spawn_worker` had already answered, so the session
    /// never became an agent. Nothing ran, but the task is in `running` with a row attached.
    case setupFailed(String)
    /// The worker was told to wind down, committed, and answered. Neither a kill nor a cap breach:
    /// the task is unfinished work with a note on it, so it must not read as failed or accepted.
    case shutdownAcknowledged(note: String?)

    var sessionState: SessionState {
        switch self {
        case .capBreach, .setupFailed: return .failed
        case .stoppedByHuman, .vanished, .shutdownAcknowledged: return .stopped
        }
    }

    var flagsTaskFailed: Bool {
        switch self {
        case .capBreach, .vanished, .setupFailed: return true
        case .stoppedByHuman, .shutdownAcknowledged: return false
        }
    }

    var reason: String {
        switch self {
        case .capBreach(let breach): return breach
        case .stoppedByHuman: return "stopped from Agent Board by a human"
        case .vanished: return "the session is no longer running and Agent Board did not stop it"
        case .setupFailed(let detail): return "setting up the worktree failed before the worker started: \(detail)"
        case .shutdownAcknowledged: return "wound down for the project shutdown order and acknowledged"
        }
    }

    var reportKind: ReportKind {
        switch self {
        case .shutdownAcknowledged: return .decision
        case .capBreach, .stoppedByHuman, .vanished, .setupFailed: return .failed
        }
    }

    var headline: String {
        switch self {
        case .shutdownAcknowledged: return "Worker wound down for the shutdown order: \(reason)"
        case .setupFailed: return "Worker never started: \(reason)"
        case .capBreach, .stoppedByHuman, .vanished: return "Worker session ended without reporting: \(reason)"
        }
    }

    /// The worker's own account of where it stopped, carried into the report the orchestrator reads.
    var detail: String? {
        switch self {
        case .shutdownAcknowledged(let note):
            guard let note, !note.isEmpty else { return nil }
            return note
        case .capBreach, .stoppedByHuman, .vanished, .setupFailed: return nil
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
            if try ShutdownOrderStore.outstanding(db, projectId: task.projectId) != nil {
                return .refused(reason: ShutdownOrder.refusal)
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

    /// Raises the shutdown order and queues a `decision` report, because an orchestrator that is
    /// not told keeps calling `spawn_worker` and reading the refusals as transient. Re-raising an
    /// outstanding order returns it without a second report.
    @discardableResult
    public func requestShutdown(projectId: String, requestedBy: String, reason: String? = nil) throws -> ShutdownOrder {
        try db.writer.write { db in
            let (order, isNew) = try ShutdownOrderStore.request(
                db, projectId: projectId, requestedBy: requestedBy, reason: reason
            )
            guard isNew else { return order }
            var body = """
            A shutdown order is active on this project. No further spawns will succeed: spawn_worker \
            is refused, and a pending spawn or integration approval cannot be approved, until the \
            order is cancelled.

            The board itself is untouched. Keep grooming, promoting proposals, and editing tasks; \
            workers already running are not affected by this order.
            """
            if let reason, !reason.isEmpty {
                body += "\n\nReason: \(reason)"
            }
            body += "\n\nRequested by: \(requestedBy)"
            _ = try ReportStore.insert(
                db, projectId: projectId, taskId: nil, sessionId: nil, kind: .decision, body: body
            )
            return order
        }
    }

    /// Cancels the outstanding order and queues the matching `decision` report; nil when there was
    /// none, in which case nothing is written. Touches no task, session or approval.
    @discardableResult
    public func cancelShutdown(projectId: String, by: String) throws -> ShutdownOrder? {
        try db.writer.write { db in
            guard let order = try ShutdownOrderStore.cancel(db, projectId: projectId, by: by) else {
                return nil
            }
            _ = try ReportStore.insert(
                db, projectId: projectId, taskId: nil, sessionId: nil, kind: .decision,
                body: """
                The shutdown order on this project was cancelled. Spawning workers is allowed again; \
                dispatch as normal.

                Cancelled by: \(by)
                """
            )
            return order
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

    /// A worker's half of the wind-down: the resume note is recorded against the order and the task,
    /// and nothing else moves. Stopping the session and terminating the row is Agent Board's half,
    /// because the worker cannot be trusted to still be alive once it has been told to stop.
    @discardableResult
    public func acknowledgeShutdown(sessionId: String, note: String) throws -> ShutdownAcknowledgement {
        try db.writer.write { db in
            guard let session = try AgentSession.fetchOne(db, key: sessionId) else {
                throw BoardError.sessionNotFound(sessionId)
            }
            guard let order = try ShutdownOrderStore.outstanding(db, projectId: session.projectId) else {
                throw BoardError.noShutdownOrder(session.projectId)
            }
            let delivery = try ShutdownDeliveryStore.acknowledge(
                db, orderId: order.id, sessionId: sessionId, taskId: session.taskId, note: note, at: .nowMillis
            )
            if let taskId = session.taskId {
                _ = try ProgressStore.append(
                    db, taskId: taskId, sessionId: sessionId, kind: .status,
                    text: "Shutdown acknowledged: \(note)"
                )
            }
            return ShutdownAcknowledgement(order: order, delivery: delivery, projectId: session.projectId, taskId: session.taskId)
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
            // The row is written before any agent process exists, so the task is visibly claimed
            // while the worktree is still being prepared.
            session.state = .setup
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
            let mergedEpicId = try Self.epicMergedBy(db, task)
            let sweepsOnMerge = try mergedEpicId != nil
                && Self.settings(db, projectId: task.projectId).archivePolicy == .afterEpicMerge
            // Under afterEpicMerge the integration task lands in `done` rather than `review`: the epic
            // reaching `done` in this same transaction is its acceptance, and a task the sweep is about
            // to archive has no business sitting in the review queue. Every other policy leaves it in
            // `review` for a human, exactly as before.
            try TaskStore.move(db, taskId, to: sweepsOnMerge ? .done : .review, before: nil)
            try SessionStore.setState(db, sessionId, .completed, endedAt: .nowMillis)
            if let mergedEpicId {
                try EpicStore.setState(db, mergedEpicId, .done)
                if sweepsOnMerge {
                    _ = try ArchiveSweep.archiveEpic(db, epicId: mergedEpicId, at: .nowMillis)
                }
            }
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
            if let epicId = task.epicId, try Epic.fetchOne(db, key: epicId)?.state == .planning {
                try EpicStore.setState(db, epicId, .active)
            }
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
            var lines = [
                cause.headline,
                "Task: \(taskId) (\(task.title))",
                "Session: \(sessionId) (attempt \(session.attempt))",
                stranded
                    ? "The task is back in ready; dispatch it again if you want it retried."
                    : "The task stayed in \(task.column.rawValue).",
            ]
            if let detail = cause.detail {
                lines.append("Where the worker stopped and what remains:\n\(detail)")
            }
            return try ReportStore.insert(
                db, projectId: session.projectId, taskId: taskId, sessionId: sessionId,
                kind: cause.reportKind, body: lines.joined(separator: "\n")
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

    /// Creates the epic and every task in `tasks` in one transaction, wiring `task_dep` rows from
    /// `NewEpicTask.dependsOn`, then refreshes readiness so dependency-free tasks leave `backlog`.
    /// `dependsOn` holds zero-based indices into the same `tasks` array; an index out of range or
    /// pointing at its own task throws `BoardError.invalidEpicDependency` and rolls the whole batch back.
    @discardableResult
    public func createEpic(projectId: String, title: String, goal: String?, tasks: [NewEpicTask]) throws -> (Epic, [Task]) {
        try db.writer.write { db in
            let epic = try EpicStore.insert(db, projectId: projectId, title: title, goal: goal)
            var created: [Task] = []
            for spec in tasks {
                created.append(try TaskStore.insert(
                    db, projectId: projectId, title: spec.title, body: spec.body,
                    acceptance: spec.acceptance, priority: spec.priority, column: .backlog,
                    origin: spec.origin, epicId: epic.id, model: spec.model
                ))
            }
            for (index, spec) in tasks.enumerated() {
                for dependency in Set(spec.dependsOn) {
                    guard created.indices.contains(dependency), dependency != index else {
                        throw BoardError.invalidEpicDependency(taskIndex: index, dependsOn: dependency)
                    }
                    try TaskDep(taskId: created[index].id, dependsOn: created[dependency].id).insert(db)
                }
            }
            _ = try Self.newlyReady(db, projectId: projectId)
            let refreshed = try TaskStore.list(db, projectId: projectId, column: nil, epicId: epic.id)
            let byId = Dictionary(uniqueKeysWithValues: refreshed.map { ($0.id, $0) })
            return (epic, created.compactMap { byId[$0.id] })
        }
    }

    /// The synthetic task the integrator is bound to, so its worker token, its report routing and
    /// its board card behave exactly as they do for any other worker. Completing it moves the epic
    /// to `done` in the same transaction as the report (see `complete`).
    @discardableResult
    public func createIntegrationTask(epicId: String) throws -> Task {
        try db.writer.write { db in
            guard let epic = try Epic.fetchOne(db, key: epicId) else {
                throw BoardError.epicNotFound(epicId)
            }
            return try TaskStore.insert(
                db, projectId: epic.projectId, title: IntegrationPlan.taskTitle(epic: epic), body: nil,
                acceptance: nil, priority: nil, column: .ready, origin: .integration, epicId: epicId
            )
        }
    }

    /// The only path that creates an `integration` approval row: `request_integration` and the epic
    /// lane button both land here. A pending request is returned as-is rather than duplicated.
    @discardableResult
    public func requestIntegration(epicId: String, requestedBy: String) throws -> Approval {
        try db.writer.write { db in
            guard let epic = try Epic.fetchOne(db, key: epicId) else {
                throw BoardError.epicNotFound(epicId)
            }
            if let existing = try ApprovalStore.pendingIntegration(db, epicId: epicId) {
                return existing
            }
            return try ApprovalStore.insert(
                db, projectId: epic.projectId, kind: .integration, taskId: nil, epicId: epicId,
                requestedBy: requestedBy, reason: nil
            )
        }
    }

    /// The only path that creates a `push` or `pull_request` approval row. Pushing and opening a
    /// pull request are outward-facing and cannot be taken back, so both wait on a human regardless
    /// of the autonomy setting — the same rule integration follows. A pending request for the same
    /// branch is returned as-is rather than duplicated.
    @discardableResult
    public func requestPublish(
        projectId: String,
        kind: ApprovalKind,
        request: PublishRequest,
        taskId: String? = nil,
        epicId: String? = nil,
        requestedBy: String,
        reason: String? = nil
    ) throws -> Approval {
        try db.writer.write { db in
            guard try Project.exists(db, key: projectId) else {
                throw BoardError.projectNotFound(projectId)
            }
            if let existing = try ApprovalStore.pendingPublish(
                db, projectId: projectId, kind: kind, branch: request.branch
            ) {
                return existing
            }
            return try ApprovalStore.insert(
                db, projectId: projectId, kind: kind, taskId: taskId, epicId: epicId,
                requestedBy: requestedBy, reason: reason, payload: try request.encoded()
            )
        }
    }

    /// What the board keeps once a `push` or `pull_request` approval has actually run: a `progress`
    /// row on the epic's or task's card carrying the pull request URL, and a `decision` report so
    /// the orchestrator reads the outcome through `list_reports` rather than a terminal.
    @discardableResult
    public func recordPublished(
        approval: Approval, summary: String, url: String? = nil, failed: Bool = false
    ) throws -> Report {
        try db.writer.write { db in
            let text = url.map { "\(summary)\n\($0)" } ?? summary
            if let taskId = try Self.publishProgressTask(db, approval) {
                _ = try ProgressStore.append(
                    db, taskId: taskId, sessionId: nil, kind: failed ? .error : .status, text: text
                )
            }
            return try ReportStore.insert(
                db, projectId: approval.projectId, taskId: approval.taskId, sessionId: nil,
                kind: .decision, body: text
            )
        }
    }

    /// The card a publish outcome belongs on. An epic-scoped approval names no task, so it lands on
    /// the epic's integrator task when there is one and on its last task otherwise.
    static func publishProgressTask(_ db: Database, _ approval: Approval) throws -> String? {
        if let taskId = approval.taskId, try Task.exists(db, key: taskId) { return taskId }
        guard let epicId = approval.epicId else { return nil }
        if let integrator = try String.fetchOne(
            db,
            sql: "SELECT id FROM task WHERE epic_id = ? AND origin = 'integration' ORDER BY created_at DESC LIMIT 1",
            arguments: [epicId]
        ) {
            return integrator
        }
        return try String.fetchOne(
            db, sql: "SELECT id FROM task WHERE epic_id = ? ORDER BY ordering DESC LIMIT 1", arguments: [epicId]
        )
    }

    /// True when the epic holds at least one task and every one of them is in `done`.
    public func epicReadyForIntegration(epicId: String) throws -> Bool {
        try db.reader.read { db in
            guard try Epic.exists(db, key: epicId) else {
                throw BoardError.epicNotFound(epicId)
            }
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task WHERE epic_id = ?", arguments: [epicId]) ?? 0
            let unfinished = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM task WHERE epic_id = ? AND column_name != 'done'",
                arguments: [epicId]
            ) ?? 0
            return total > 0 && unfinished == 0
        }
    }

    /// The epic this report finishes, if the task is the synthetic integrator task and the epic is
    /// still `integrating`; nil for every ordinary task.
    static func epicMergedBy(_ db: Database, _ task: Task) throws -> String? {
        guard task.origin == .integration, let epicId = task.epicId,
              try Epic.fetchOne(db, key: epicId)?.state == .integrating
        else { return nil }
        return epicId
    }

    static func settings(_ db: Database, projectId: String) throws -> ProjectSettings {
        guard let project = try Project.fetchOne(db, key: projectId) else {
            throw BoardError.projectNotFound(projectId)
        }
        return project.settings
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

/// One task in a `Board.createEpic` batch. `dependsOn` holds zero-based indices into the same batch.
public struct NewEpicTask: Sendable, Equatable {
    public var title: String
    public var body: String?
    public var acceptance: String?
    public var priority: String?
    public var model: String?
    public var origin: TaskOrigin
    public var dependsOn: [Int]

    public init(
        title: String, body: String? = nil, acceptance: String? = nil, priority: String? = nil,
        model: String? = nil, origin: TaskOrigin = .orchestrator, dependsOn: [Int] = []
    ) {
        self.title = title
        self.body = body
        self.acceptance = acceptance
        self.priority = priority
        self.model = model
        self.origin = origin
        self.dependsOn = dependsOn
    }
}


public struct ShutdownAcknowledgement: Sendable, Equatable {
    public var order: ShutdownOrder
    public var delivery: ShutdownDelivery
    public var projectId: String
    public var taskId: String?

    public init(order: ShutdownOrder, delivery: ShutdownDelivery, projectId: String, taskId: String?) {
        self.order = order
        self.delivery = delivery
        self.projectId = projectId
        self.taskId = taskId
    }
}
