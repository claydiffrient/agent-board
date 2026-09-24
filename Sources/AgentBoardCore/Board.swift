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

    /// Whether committed work on the task branch should divert a stranded task to `review` rather
    /// than `ready`. A wind-down acknowledgment has its own resume-note contract, and a setup
    /// failure never ran a worker, so neither gets to reinterpret what is on the branch.
    var salvagesBranchWork: Bool {
        switch self {
        case .capBreach, .vanished, .stoppedByHuman: return true
        case .setupFailed, .shutdownAcknowledged: return false
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

    /// The only path that creates a worker session row. The two guards run inside the write
    /// transaction, so a handed-off task cannot be assigned twice concurrently: one caller wins and
    /// the other throws rather than launching a second agent into the same checkout.
    @discardableResult
    public func assign(taskId: String, session: AgentSession) throws -> AgentSession {
        try db.writer.write { db in
            guard let task = try Task.fetchOne(db, key: taskId) else {
                throw BoardError.taskNotFound(taskId)
            }
            if let holder = try SessionStore.activeHolder(db, taskId: taskId) {
                throw BoardError.taskAlreadyHeld(taskId: taskId, sessionId: holder.sessionId)
            }
            if let path = session.worktreePath, let holder = try SessionStore.activeHolder(db, worktreePath: path) {
                throw BoardError.worktreeAlreadyHeld(path: path, sessionId: holder.sessionId)
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
            // A rostered assignment is readable from the task as well as the session, so the board,
            // Status and the next agent in a handoff can all see who is on it.
            try TaskStore.setRosterAgent(db, taskId, session.rosterAgentId)
            try TaskStore.setBlocked(db, taskId, false, reason: nil)
            try TaskStore.setFailed(db, taskId, false, reason: nil)
            try TaskStore.move(db, taskId, to: .running, before: nil)
            return session
        }
    }

    /// The reviewer's counterpart to `assign`. A review holds a task that is already in `review` and
    /// must stay there: moving it to `running` would take it out of the review queue and make the
    /// reviewer's own `accept_task` guard refuse. Nothing is written to the task at all.
    @discardableResult
    public func assignReviewer(taskId: String, session: AgentSession) throws -> AgentSession {
        try db.writer.write { db in
            let task = try Self.requireTask(db, taskId)
            guard task.column == .review else {
                throw BoardError.taskNotInReview(taskId: taskId, column: task.column)
            }
            if let holder = try SessionStore.activeHolder(db, taskId: taskId) {
                throw BoardError.taskAlreadyHeld(taskId: taskId, sessionId: holder.sessionId)
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
            session.state = .setup
            session.attempt = previousAttempts + 1
            try session.insert(db)
            return session
        }
    }

    /// A finished task and where the project's review level sends it. `autoAccept` is the caller's
    /// cue to run `accept` — the same call a human Accept makes — rather than a second accept path.
    ///
    /// `report_complete` reaches the server more than once for one tool call: the handler stops the
    /// worker before answering it, the answer is lost with the process, and the MCP client resends.
    /// A resent call finds the first report and re-runs nothing, so `wasAlreadyComplete` is what
    /// tells the caller to route none of it again — no acceptance, no reviewer, no events. SPEC §5.
    public struct CompletionOutcome: Sendable {
        public var report: Report
        public var level: ReviewLevel
        public var routing: ReviewRouting
        /// Where the task actually sits: `review`, `done` under `afterEpicMerge`, or, on a resend,
        /// wherever it has been moved to since the first call.
        public var column: TaskColumn
        public var wasAlreadyComplete: Bool

        /// Never true on a resend: the first call already ran the acceptance path.
        public var autoAccept: Bool { routing == .autoAccept && !wasAlreadyComplete }
    }

    /// Records the report and parks the task where §5's review level says. Under `.none` (and `.epic`
    /// for a task inside an epic) the task stays in `review` for the length of this transaction only:
    /// `autoAccept` tells the caller to run the ordinary acceptance path, which is where the
    /// newly-ready announcement, grant revocation and worktree removal live.
    ///
    /// A second call from the same session returns the first report with `wasAlreadyComplete` set and
    /// writes nothing — the guard reads inside this write transaction, so two concurrent resends
    /// cannot both pass it, and the review routing below never runs twice.
    @discardableResult
    public func complete(taskId: String, sessionId: String, summary: String) throws -> CompletionOutcome {
        try db.writer.write { db in
            let task = try Self.requireTask(db, taskId)
            if let existing = try ReportStore.completion(db, taskId: taskId, sessionId: sessionId) {
                return CompletionOutcome(
                    report: existing,
                    level: try ReviewPolicy.level(db, task: task),
                    routing: try ReviewPolicy.routing(db, task: task),
                    column: task.column,
                    wasAlreadyComplete: true
                )
            }
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
            let column: TaskColumn = sweepsOnMerge ? .done : .review
            try TaskStore.move(db, taskId, to: column, before: nil)
            try SessionStore.setState(db, sessionId, .completed, endedAt: .nowMillis)
            try FileLockStore.releaseAll(db, sessionId: sessionId)
            if let mergedEpicId {
                try EpicStore.setState(db, mergedEpicId, .done)
                if sweepsOnMerge {
                    _ = try ArchiveSweep.archiveEpic(db, epicId: mergedEpicId, at: .nowMillis)
                }
            }
            let level = try ReviewPolicy.level(db, task: task)
            let routing = try ReviewPolicy.routing(db, task: task)
            switch routing {
            case .autoAccept:
                break
            case .agentReview(let agentId, let agentName):
                try TaskStore.setReviewer(db, taskId, agentId)
                _ = try ProgressStore.append(
                    db, taskId: taskId, sessionId: nil, kind: .status,
                    text: "Handed to rostered reviewer \(agentName) for agent review."
                )
            case .humanReview(let reason):
                try TaskStore.setReviewer(db, taskId, nil)
                if let reason {
                    _ = try ProgressStore.append(
                        db, taskId: taskId, sessionId: nil, kind: .status, text: reason
                    )
                }
            }
            return CompletionOutcome(
                report: report, level: level, routing: routing, column: column, wasAlreadyComplete: false
            )
        }
    }

    /// A rostered agent finishing its portion: the task goes back to `ready` with a progress row and a
    /// report, the session's hold is released so nothing believes it is still working, and the worktree
    /// is left in place for whoever picks the task up next. This is not a failure and never flags one.
    @discardableResult
    public func handOff(
        taskId: String, sessionId: String, summary: String, nextRole: String?, filesChanged: [String]
    ) throws -> Report {
        try db.writer.write { db in
            let task = try Self.requireTask(db, taskId)
            guard let session = try AgentSession.fetchOne(db, key: sessionId),
                  session.taskId == taskId, session.state.isActive
            else {
                throw BoardError.sessionNotOnTask(sessionId: sessionId, taskId: taskId)
            }
            let agent = session.shortId ?? sessionId
            let suggested = nextRole.flatMap { $0.isEmpty ? nil : $0 }

            var lines = [
                "Handed off by \(agent) (attempt \(session.attempt)) after doing its portion.",
                summary,
            ]
            if !filesChanged.isEmpty {
                lines.append("Files changed: " + filesChanged.joined(separator: ", "))
            }
            lines.append(suggested.map { "Suggested next role: \($0) (advisory; you decide who gets it)." }
                ?? "No next role suggested.")
            lines.append("Task \(taskId) (\(task.title)) is back in ready. Its worktree is retained, so the "
                + "next agent works the same checkout; nothing else may be dispatched into it meanwhile.")
            let body = lines.joined(separator: "\n\n")

            let report = try ReportStore.insert(
                db, projectId: task.projectId, taskId: taskId, sessionId: sessionId, kind: .handoff, body: body
            )
            _ = try ProgressStore.append(db, taskId: taskId, sessionId: sessionId, kind: .note, text: body)
            try TaskStore.setBlocked(db, taskId, false, reason: nil)
            try TaskStore.setFailed(db, taskId, false, reason: nil)
            try TaskStore.move(db, taskId, to: .ready, before: nil)
            try SessionStore.setState(db, sessionId, .completed, endedAt: .nowMillis)
            try SessionStore.setStopReason(db, sessionId, suggested.map { "handed off to \($0)" } ?? "handed off")
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

    /// What a shared-checkout worker's `report_blocked` does when it gave up waiting for another
    /// session's file lock: unlike an ordinary block, the task goes back to `ready` and the session
    /// ends, because the work is queued behind a file rather than behind a human.
    @discardableResult
    public func blockOnFileLock(taskId: String, sessionId: String, reason: String) throws -> Report {
        try db.writer.write { db in
            let task = try Self.requireTask(db, taskId)
            let report = try ReportStore.insert(
                db, projectId: task.projectId, taskId: taskId, sessionId: sessionId, kind: .blocked,
                body: reason + "\n\nThe task is back in ready; dispatch it again once the file is free."
            )
            try TaskStore.setBlocked(db, taskId, true, reason: reason)
            if task.column == .running {
                try TaskStore.move(db, taskId, to: .ready, before: nil)
            }
            try SessionStore.setState(db, sessionId, .stopped, endedAt: .nowMillis)
            try SessionStore.setStopReason(db, sessionId, reason)
            try db.execute(
                sql: "UPDATE agent_session SET blocked_on_path = NULL WHERE session_id = ?",
                arguments: [sessionId]
            )
            try FileLockStore.releaseAll(db, sessionId: sessionId)
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
    /// only signal that the dependency graph moved. Every review level lands here — `acceptedBy` only
    /// changes who the report names, never what happens.
    @discardableResult
    public func accept(taskId: String, acceptedBy: TaskAcceptance = .human) throws -> [String] {
        try db.writer.write { db in
            try Self.accept(db, taskId: taskId, acceptedBy: acceptedBy)
        }
    }

    static func accept(_ db: Database, taskId: String, acceptedBy: TaskAcceptance) throws -> [String] {
        let task = try requireTask(db, taskId)
        try TaskStore.setBlocked(db, taskId, false, reason: nil)
        try TaskStore.setFailed(db, taskId, false, reason: nil)
        try TaskStore.move(db, taskId, to: .done, before: nil)
        if let epicId = task.epicId, try Epic.fetchOne(db, key: epicId)?.state == .planning {
            try EpicStore.setState(db, epicId, .active)
        }
        let ready = try newlyReady(db, projectId: task.projectId)
        var body = "Task \(taskId) (\(task.title)) was accepted into done by \(acceptedBy.describedActor)."
        if case .reviewer(_, let verdict, _) = acceptedBy, !verdict.isEmpty {
            body += "\n\n" + verdict
        }
        body += "\n\n" + (try describeNewlyReady(db, ready))
        _ = try ReportStore.insert(
            db, projectId: task.projectId, taskId: taskId, sessionId: nil, kind: .decision, body: body
        )
        return ready
    }

    /// Puts a rostered reviewer's approval on the task before the acceptance itself runs, so a person
    /// reading a task that reached `done` without them can see who approved it and why. The accept that
    /// follows is the ordinary one — this deliberately does not move the task.
    public func recordReviewVerdict(
        taskId: String, sessionId: String?, reviewerName: String, verdict: String
    ) throws {
        try db.writer.write { db in
            let task = try Self.requireTask(db, taskId)
            guard task.column == .review else {
                throw BoardError.invalidTransition(taskId: taskId, from: task.column, to: .done)
            }
            _ = try ProgressStore.append(
                db, taskId: taskId, sessionId: sessionId, kind: .note,
                text: "Agent review passed. Reviewer \(reviewerName) accepted this task into done.\n\n\(verdict)"
            )
        }
    }

    /// A rostered reviewer rejecting its task: back to `ready` with its findings on the task, so the
    /// next agent picks the work up knowing what was wrong.
    @discardableResult
    public func reviewReopen(
        taskId: String, sessionId: String?, reviewerName: String, findings: String
    ) throws -> Report {
        try db.writer.write { db in
            let task = try Self.requireTask(db, taskId)
            guard task.column == .review else {
                throw BoardError.invalidTransition(taskId: taskId, from: task.column, to: .ready)
            }
            let body = "Agent review failed. Reviewer \(reviewerName) sent task \(taskId) (\(task.title)) "
                + "back to ready.\n\n\(findings)"
            _ = try ProgressStore.append(db, taskId: taskId, sessionId: sessionId, kind: .note, text: body)
            try TaskStore.setBlocked(db, taskId, false, reason: nil)
            try TaskStore.setFailed(db, taskId, false, reason: nil)
            try TaskStore.setReviewer(db, taskId, nil)
            try TaskStore.move(db, taskId, to: .ready, before: nil)
            return try ReportStore.insert(
                db, projectId: task.projectId, taskId: taskId, sessionId: sessionId, kind: .decision, body: body
            )
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
    /// orchestrator stops believing the worker is running. A task stranded in `running` leaves it:
    /// for `review` when `salvage` shows commits on its branch, otherwise back to `ready`.
    ///
    /// An already-inactive session row is not a reason to stop. The worker's `SessionEnd` hook races
    /// this call and writes `stopped` first often enough that bailing there strands the task in
    /// `running` with no report and nothing able to pick it up.
    @discardableResult
    public func terminate(
        sessionId: String, cause: SessionTermination, salvage: BranchSalvage? = nil
    ) throws -> Report? {
        try db.writer.write { db in
            guard let session = try AgentSession.fetchOne(db, key: sessionId) else { return nil }
            let task = session.role == .worker
                ? try session.taskId.flatMap { try Task.fetchOne(db, key: $0) }
                : nil
            let stranded = task?.column == .running
            guard session.state.isActive || stranded else { return nil }

            let reason = cause.reason
            if session.state.isActive {
                try SessionStore.setState(db, sessionId, cause.sessionState, endedAt: .nowMillis)
            }
            try SessionStore.setStopReason(db, sessionId, reason)
            // Every route out of a session lands here or in `complete`: a cap kill, a human stop,
            // a vanished process, a failed setup, an acknowledged wind-down. A lock that outlived
            // one of them would block the checkout with nobody behind it.
            try FileLockStore.releaseAll(db, sessionId: sessionId)
            guard let task else { return nil }
            let taskId = task.id

            try TaskStore.setBlocked(db, taskId, false, reason: nil)
            if cause.flagsTaskFailed {
                try TaskStore.setFailed(db, taskId, true, reason: reason)
            }
            let destination = Self.landingColumn(stranded: stranded, cause: cause, salvage: salvage)
            if let destination {
                try TaskStore.move(db, taskId, to: destination, before: nil)
            }
            var lines = [
                cause.headline,
                "Task: \(taskId) (\(task.title))",
                "Session: \(sessionId) (attempt \(session.attempt))",
            ]
            if let salvage { lines.append(salvage.sentence) }
            lines.append(Self.landingLine(destination: destination, stayedIn: task.column))
            if let detail = cause.detail {
                lines.append("Where the worker stopped and what remains:\n\(detail)")
            }
            return try ReportStore.insert(
                db, projectId: session.projectId, taskId: taskId, sessionId: sessionId,
                kind: cause.reportKind, body: lines.joined(separator: "\n")
            )
        }
    }

    /// Nil when the task was not in `running` and so is not moved at all.
    static func landingColumn(
        stranded: Bool, cause: SessionTermination, salvage: BranchSalvage?
    ) -> TaskColumn? {
        guard stranded else { return nil }
        guard cause.salvagesBranchWork, salvage?.hasCommittedWork == true else { return .ready }
        return .review
    }

    static func landingLine(destination: TaskColumn?, stayedIn column: TaskColumn) -> String {
        switch destination {
        case .review:
            return "The task is in review, not ready, so a retry cannot silently redo that work. "
                + "Read the branch, then accept it or reopen the task to hand it back to a worker."
        case .ready:
            return "The task is back in ready; dispatch it again if you want it retried."
        default:
            return "The task stayed in \(column.rawValue)."
        }
    }

    /// Tasks in `running` that no active session owns. Nothing can act on one: `spawn_worker` takes
    /// only a `ready` task and no report is coming, so it is invisible until a human moves it by hand.
    /// Returned rather than fixed here, so the caller can read each branch before deciding where it lands.
    public func strandedRunningTasks(projectId: String) throws -> [BoardTask] {
        try db.reader.read { db in
            try Task.fetchAll(
                db,
                sql: """
                SELECT t.* FROM task t
                WHERE t.project_id = ? AND t.column_name = ?
                  AND NOT EXISTS (
                    SELECT 1 FROM agent_session s
                    WHERE s.task_id = t.id AND s.state IN (\(SessionStore.activeStatesSQL))
                  )
                ORDER BY t.ordering, t.created_at, t.id
                """,
                arguments: [projectId, TaskColumn.running.rawValue]
            )
        }
    }

    /// Moves a stranded task out of `running` and queues a `failed` report, whatever path its
    /// session death took — including one that left no session row at all, which `terminate` has
    /// no handle on. Re-checks the strand inside the write, so a task that has since moved or
    /// gained an active session is left exactly where it is.
    @discardableResult
    public func recoverStranded(taskId: String, salvage: BranchSalvage? = nil) throws -> Report? {
        try db.writer.write { db in
            guard let task = try Task.fetchOne(db, key: taskId), task.column == .running else { return nil }
            let sessions = try AgentSession.fetchAll(
                db,
                sql: "SELECT * FROM agent_session WHERE task_id = ? ORDER BY attempt DESC, started_at DESC",
                arguments: [taskId]
            )
            guard !sessions.contains(where: { $0.state.isActive }) else { return nil }

            let reason = "the task was left in running with no active session and no report"
            try TaskStore.setBlocked(db, taskId, false, reason: nil)
            try TaskStore.setFailed(db, taskId, true, reason: reason)
            let destination: TaskColumn = salvage?.hasCommittedWork == true ? .review : .ready
            try TaskStore.move(db, taskId, to: destination, before: nil)

            var lines = [
                "Task stranded in running: \(reason).",
                "Task: \(taskId) (\(task.title))",
                sessions.first.map { "Last session: \($0.sessionId) (attempt \($0.attempt)), \($0.state.rawValue)" }
                    ?? "No session was ever recorded for this task.",
            ]
            if let salvage { lines.append(salvage.sentence) }
            lines.append(Self.landingLine(destination: destination, stayedIn: task.column))
            return try ReportStore.insert(
                db, projectId: task.projectId, taskId: taskId, sessionId: sessions.first?.sessionId,
                kind: .failed, body: lines.joined(separator: "\n")
            )
        }
    }

    @discardableResult
    public func propose(
        projectId: String, title: String, body: String?, rationale: String?, sessionId: String?,
        epicId: String?
    ) throws -> Task {
        try db.writer.write { db in
            if let epicId {
                _ = try Self.proposalEpic(db, epicId: epicId, projectId: projectId)
            }
            let task = try TaskStore.insert(
                db, projectId: projectId, title: title, body: body, acceptance: nil, priority: nil,
                column: .proposed, origin: .workerProposal, epicId: epicId
            )
            var lines = ["Proposed task: \(title)", "Task id: \(task.id)"]
            if let epicId { lines.append("Proposed into epic: \(epicId)") }
            if let body, !body.isEmpty { lines.append(body) }
            if let rationale, !rationale.isEmpty { lines.append("Rationale: \(rationale)") }
            _ = try ReportStore.insert(
                db, projectId: projectId, taskId: task.id, sessionId: sessionId, kind: .proposal,
                body: lines.joined(separator: "\n\n")
            )
            return task
        }
    }

    /// The epic a proposal names must still be a destination when the proposal is promoted, which
    /// can be much later — so this re-checks and, when the epic has stopped being one, promotes the
    /// task into no epic and says so on the decision report rather than refusing the promotion or
    /// dropping an unfinished task into a finished epic. SPEC §5.
    @discardableResult
    public func promote(taskId: String) throws -> Promotion {
        try db.writer.write { db in
            let task = try Self.requireTask(db, taskId)
            guard task.column == .proposed else {
                throw BoardError.invalidTransition(taskId: taskId, from: task.column, to: .backlog)
            }
            var dropped: ProposalEpicRefusal?
            if let epicId = task.epicId {
                do {
                    _ = try Self.proposalEpic(db, epicId: epicId, projectId: task.projectId)
                } catch let refusal as ProposalEpicRefusal {
                    dropped = refusal
                    try TaskStore.setEpic(db, taskId, epicId: nil)
                }
            }
            try TaskStore.move(db, taskId, to: .backlog, before: nil)
            let ready = try Self.newlyReady(db, projectId: task.projectId)
            let landed = try Task.fetchOne(db, key: taskId)?.column ?? .backlog
            var body = "Proposal \(taskId) (\(task.title)) was promoted to \(landed.rawValue)."
            if let dropped, let named = task.epicId {
                body += "\n\nIt was proposed into epic \(named) but promoted into no epic: \(dropped.reason)"
            }
            body += "\n\n" + (try Self.describeNewlyReady(db, ready))
            _ = try ReportStore.insert(
                db, projectId: task.projectId, taskId: taskId, sessionId: nil, kind: .decision, body: body
            )
            return Promotion(newlyReady: ready, landedIn: landed, droppedEpic: dropped)
        }
    }

    static func proposalEpic(_ db: Database, epicId: String, projectId: String) throws -> Epic {
        guard let epic = try Epic.fetchOne(db, key: epicId) else {
            throw ProposalEpicRefusal.notFound(epicId)
        }
        guard epic.projectId == projectId else {
            throw ProposalEpicRefusal.otherProject(epicId: epicId)
        }
        guard !epic.state.isTerminal else {
            throw ProposalEpicRefusal.closed(epicId: epicId, state: epic.state)
        }
        return epic
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

    /// What closing this epic would do, read before the human is asked to confirm it. The same
    /// query backs `closeEpic`'s guards, so the dialog cannot promise something the write refuses.
    public func epicClosurePlan(epicId: String, as closure: EpicClosure) throws -> EpicClosurePlan {
        try db.reader.read { db in try Self.closurePlan(db, epicId: epicId, as: closure) }
    }

    /// A human ends the epic without driving it through integration: the terminal state is written,
    /// a `decision` report tells the orchestrator to stop planning into it, and nothing else moves.
    /// No branch is merged or deleted, no worktree is removed, and no task is deleted, archived or
    /// re-homed — unfinished tasks stay in this epic's lane exactly as they are, because rewriting a
    /// human's unfinished work is not what "I am finished with this epic" asks for.
    ///
    /// Refused while any session in the epic is still active, so a live worker is never left running
    /// against a closed epic, and refused for an epic that is already terminal: `done` and
    /// `abandoned` mean different things and one does not silently become the other.
    @discardableResult
    public func closeEpic(epicId: String, as closure: EpicClosure, by: String) throws -> Report {
        try db.writer.write { db in
            let plan = try Self.closurePlan(db, epicId: epicId, as: closure)
            if let state = plan.alreadyClosed {
                throw BoardError.epicAlreadyClosed(epicId: epicId, state: state)
            }
            guard plan.running.isEmpty else {
                throw BoardError.epicHasRunningWorkers(epicId: epicId, sessionIds: plan.running.map(\.sessionId))
            }
            guard let epic = try Epic.fetchOne(db, key: epicId) else {
                throw BoardError.epicNotFound(epicId)
            }
            try EpicStore.setState(db, epicId, closure.state)

            var lines = [
                "Epic \(epicId) (\(epic.title)) was closed as \(closure.state.rawValue) by a human, "
                    + "without being integrated. Do not plan or dispatch further work into it.",
                "Nothing was merged, pushed or deleted: the epic branch \(epic.branch) and every "
                    + "`agentboard/<task-id>` branch and worktree are untouched.",
            ]
            if plan.unfinished.isEmpty {
                lines.append("Every task in the epic was already finished.")
            } else {
                let listed = plan.unfinished.map { "- \($0.id) (\($0.title)) in \($0.column.rawValue)" }
                    .joined(separator: "\n")
                lines.append(
                    "\(plan.unfinished.count) task(s) were left unfinished and stay in this epic exactly "
                        + "as they are — not deleted, not archived, not moved out:\n\(listed)"
                )
                lines.append(
                    "If any of that work still matters, take it out of the epic with "
                        + "set_epic(task_id) and no epic_id, and it stands alone on the board."
                )
            }
            lines.append("Closed by: \(by)")
            return try ReportStore.insert(
                db, projectId: epic.projectId, taskId: nil, sessionId: nil, kind: .decision,
                body: lines.joined(separator: "\n\n")
            )
        }
    }

    static func closurePlan(_ db: Database, epicId: String, as closure: EpicClosure) throws -> EpicClosurePlan {
        guard let epic = try Epic.fetchOne(db, key: epicId) else {
            throw BoardError.epicNotFound(epicId)
        }
        let unfinished = try Task
            .fetchAll(
                db,
                sql: "SELECT * FROM task WHERE epic_id = ? AND column_name != 'done' ORDER BY ordering",
                arguments: [epicId]
            )
            .map { EpicUnfinishedTask(id: $0.id, title: $0.title, column: $0.column) }
        let running = try Row
            .fetchAll(
                db,
                sql: """
                SELECT s.session_id AS session_id, s.short_id AS short_id, t.title AS title
                FROM agent_session s
                JOIN task t ON t.id = s.task_id
                WHERE t.epic_id = ? AND s.state IN (\(SessionStore.activeStatesSQL))
                ORDER BY s.started_at
                """,
                arguments: [epicId]
            )
            .map {
                EpicRunningWorker(
                    sessionId: $0["session_id"], shortId: $0["short_id"], taskTitle: $0["title"]
                )
            }
        return EpicClosurePlan(
            epicId: epic.id,
            epicTitle: epic.title,
            branch: epic.branch,
            closure: closure,
            alreadyClosed: epic.state.isTerminal ? epic.state : nil,
            unfinished: unfinished,
            running: running
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
