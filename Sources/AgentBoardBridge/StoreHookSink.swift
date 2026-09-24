import AgentBoardCore
import AgentBoardServer
import Foundation

public final class StoreHookSink: HookSink {
    private let hookEvents: HookEventStore
    private let grants: TokenGrantStore
    private let sessions: SessionStore
    private let projects: ProjectStore
    private let tasks: TaskStore
    private let progress: ProgressStore
    private let shutdowns: ShutdownOrderStore
    private let deliveries: ShutdownDeliveryStore
    private let notes: NoteStore
    private let epics: EpicStore
    private let locks: FileLockStore
    private let waitPolicy: FileLockWaitPolicy
    private let board: Board
    private let db: AppDatabase
    private let events: any BoardEventSink
    private let queue = DispatchQueue(label: "agent-board.hooks")
    /// Sessions whose context was just compacted and that have not yet been handed their task back.
    /// Touched only from `queue`. Deliberately not persisted: the re-brief is worth nothing to a
    /// session that has since ended, and Agent Board restarting mid-compaction loses nothing else.
    nonisolated(unsafe) private var awaitingReBrief: Set<String> = []

    public static let blockingNotificationTypes: Set<String> = ["permission_prompt", "agent_needs_input"]

    private enum FollowUp {
        case notify(projectId: String, sessionId: String?, title: String, body: String)
        case orchestratorTurnEnded(projectId: String, sessionId: String)
        case reportQueued(projectId: String)
        case orchestratorCompacted(projectId: String, sessionId: String, manual: Bool)
    }

    /// A write whose file another live session holds. Carried out of `process` so the wait happens
    /// off the hook queue, which every other session's hooks are still using.
    private struct LockWait {
        var projectId: String
        var path: String
        var sessionId: String
        var taskId: String?
        var holder: FileLock
    }

    private struct Outcome {
        var followUps: [FollowUp] = []
        var decision: HookDecision?
        var lockWait: LockWait?

        static let none = Outcome()
        static func follow(_ followUps: [FollowUp]) -> Outcome { Outcome(followUps: followUps) }
        static func deny(_ decision: HookDecision) -> Outcome { Outcome(decision: decision) }
        static func respond(_ decision: HookDecision, _ followUps: [FollowUp] = []) -> Outcome {
            Outcome(followUps: followUps, decision: decision)
        }
        static func wait(_ wait: LockWait) -> Outcome { Outcome(lockWait: wait) }
    }

    public init(db: AppDatabase, events: any BoardEventSink, lockWait: FileLockWaitPolicy = .default) {
        hookEvents = HookEventStore(db)
        grants = TokenGrantStore(db)
        sessions = SessionStore(db)
        projects = ProjectStore(db)
        tasks = TaskStore(db)
        progress = ProgressStore(db)
        shutdowns = ShutdownOrderStore(db)
        deliveries = ShutdownDeliveryStore(db)
        notes = NoteStore(db)
        epics = EpicStore(db)
        locks = FileLockStore(db)
        waitPolicy = lockWait
        board = Board(db)
        self.db = db
        self.events = events
    }

    public func handle(_ event: HookEvent, identity: TokenIdentity) async -> HookDecision? {
        let outcome: Outcome = await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.process(event, identity: identity))
            }
        }
        for followUp in outcome.followUps {
            switch followUp {
            case .notify(let projectId, let sessionId, let title, let body):
                await events.notify(
                    projectId: projectId, sessionId: sessionId, title: title, body: body
                )
            case .orchestratorTurnEnded(let projectId, let sessionId):
                await events.orchestratorTurnEnded(projectId: projectId, sessionId: sessionId)
            case .reportQueued(let projectId):
                await events.reportQueued(projectId: projectId)
            case .orchestratorCompacted(let projectId, let sessionId, let manual):
                await events.orchestratorCompacted(projectId: projectId, sessionId: sessionId, manual: manual)
            }
        }
        if let wait = outcome.lockWait {
            return await awaitFileLock(wait)
        }
        return outcome.decision
    }

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    // MARK: - Per-file locks in a shared checkout

    /// The lock a write has to hold before it runs, or nil when this session cannot collide with
    /// anyone: an orchestrator, a worker in its own worktree, or a write outside the repository.
    ///
    /// A worktree worker never reaches here at all — the matcher that routes write tools to this
    /// hook is only written into a shared session's settings file.
    private func lockRequest(_ event: HookEvent, identity: TokenIdentity, sessionId: String) -> LockWait? {
        guard identity.scope == .worker, !sessionId.isEmpty else { return nil }
        guard let session = try? sessions.get(sessionId), session.role == .worker else { return nil }
        guard session.worktreePath == nil else { return nil }
        guard let project = try? projects.get(session.projectId) else { return nil }
        guard let path = FileLockPolicy.key(filePath: event.toolFilePath, repoPath: project.repoPath)
        else { return nil }
        return LockWait(
            projectId: session.projectId, path: path, sessionId: sessionId,
            taskId: session.taskId ?? identity.taskId,
            holder: FileLock(projectId: session.projectId, path: path, sessionId: sessionId)
        )
    }

    private func isSharedWorker(_ identity: TokenIdentity, sessionId: String) -> Bool {
        guard identity.scope == .worker, !sessionId.isEmpty else { return false }
        guard let session = try? sessions.get(sessionId),
              let project = try? projects.get(session.projectId)
        else { return false }
        return SharedCheckoutGroup.isMember(session, of: project)
    }

    /// The reason to refuse a shared worker's git command, or nil when the command is the one
    /// allowed form: `git restore -- <paths>` where every path is one this session's own writes
    /// have locked. The lock store is consulted here rather than in the guard, which is in a target
    /// with no database.
    private func sharedCheckoutDenial(
        _ verdict: SharedCheckoutGuard.Verdict, sessionId: String
    ) -> (command: String, reason: String)? {
        switch verdict {
        case .allow:
            return nil
        case .deny(let violation):
            return (violation.gitCommand, violation.reason)
        case .restoreScoped(let paths):
            let restore = SharedCheckoutGuard.Violation.restore
            guard let session = try? sessions.get(sessionId),
                  let project = try? projects.get(session.projectId)
            else { return (restore.gitCommand, restore.reason) }
            let held = Set(CommitScope.paths((try? locks.held(projectId: session.projectId)) ?? [], sessionId: sessionId))
            let outside = paths.filter { path in
                guard let key = FileLockPolicy.key(filePath: path, repoPath: project.repoPath) else { return true }
                return !held.contains(key)
            }
            guard !outside.isEmpty else { return nil }
            return (restore.gitCommand, SharedCheckoutGuard.restoreOutOfScopeReason(outside))
        }
    }

    private func claim(_ request: LockWait) -> Outcome {
        guard let outcome = try? locks.acquire(
            projectId: request.projectId, path: request.path,
            sessionId: request.sessionId, taskId: request.taskId
        ) else { return .none }
        switch outcome {
        case .acquired:
            return .none
        case .heldBy(let holder):
            var wait = request
            wait.holder = holder
            return .wait(wait)
        }
    }

    /// Re-claims on a timer rather than waiting for a signal: the holder may be a detached worker
    /// in another process, so there is no in-process release to wake on.
    private func pollUntilFree(_ wait: LockWait, from started: Date) async -> Bool {
        while Date().timeIntervalSince(started) < waitPolicy.timeout {
            try? await _Concurrency.Task.sleep(nanoseconds: UInt64(waitPolicy.pollInterval * 1_000_000_000))
            let taken = await onQueue { [locks] in
                guard let outcome = try? locks.acquire(
                    projectId: wait.projectId, path: wait.path,
                    sessionId: wait.sessionId, taskId: wait.taskId
                ) else { return false }
                if case .acquired = outcome { return true }
                return false
            }
            if taken { return true }
        }
        return false
    }

    /// Holds the hook's response until the file frees or `waitPolicy.timeout` runs out. The session
    /// sits in `waitingOnLock` for the duration, which is what keeps the idle cap and the stall
    /// indicator off a worker that is doing exactly what it was told to do.
    private func awaitFileLock(_ wait: LockWait) async -> HookDecision? {
        let started = Date()
        await onQueue { [sessions] in
            try? sessions.setState(wait.sessionId, .waitingOnLock)
        }
        let acquired = await pollUntilFree(wait, from: started)
        let waited = Date().timeIntervalSince(started)
        return await onQueue { [sessions, progress, locks] in
            // Only this session's own wait is being ended; anything that reached the row while it
            // waited — a stop, a cap kill — owns the state now and must not be overwritten.
            if (try? sessions.get(wait.sessionId))?.state == .waitingOnLock {
                try? sessions.setState(wait.sessionId, .running)
            }
            // The waited seconds are not idleness, so they do not carry into the next idle window.
            // On success the write itself now starts, which is what `beginToolCall` records.
            if acquired {
                try? sessions.beginToolCall(wait.sessionId, at: .nowMillis, tool: nil)
            } else {
                try? sessions.recordActivity(wait.sessionId, at: .nowMillis, lastTool: nil)
            }
            guard !acquired else {
                if let taskId = wait.taskId {
                    _ = try? progress.append(
                        taskId: taskId, sessionId: wait.sessionId, kind: .status,
                        text: "Waited \(Int(waited))s for \(wait.path) and took the lock."
                    )
                }
                return nil
            }
            let holder = ((try? locks.holder(projectId: wait.projectId, path: wait.path)) ?? nil) ?? wait.holder
            if let taskId = wait.taskId {
                _ = try? progress.append(
                    taskId: taskId, sessionId: wait.sessionId, kind: .error,
                    text: "Gave up after \(Int(waited))s waiting for \(wait.path), held by session \(holder.sessionId)."
                )
                try? sessions.setBlockedOnPath(wait.sessionId, wait.path)
            }
            return .deny(FileLockPolicy.waitReason(path: wait.path, holder: holder, waited: waited))
        }
    }

    /// SPEC §12: denying `PreToolUse` is the only way into a busy `--bg` worker mid-turn. It fires
    /// once per session — the claim is what makes it once — so the worker's following calls go
    /// through and it can actually commit before it acknowledges.
    private func windDownToDeliver(sessionId: String, identity: TokenIdentity) -> ShutdownOrder? {
        guard identity.scope == .worker, !sessionId.isEmpty else { return nil }
        guard let order = (try? shutdowns.outstanding(projectId: identity.projectId)) ?? nil else { return nil }
        let taskId = projectSession(sessionId, identity: identity)?.taskId ?? identity.taskId
        let claimed = (try? deliveries.claimDelivery(
            orderId: order.id, sessionId: sessionId, taskId: taskId, via: .hook
        )) ?? false
        guard claimed else { return nil }
        if let taskId {
            _ = try? progress.append(
                taskId: taskId, sessionId: sessionId, kind: .status,
                text: "Wind-down order delivered; waiting for acknowledge_shutdown."
            )
        }
        return order
    }

    /// `PreCompact`'s own response cannot carry context: per the hook reference its only decision
    /// field is a top-level `decision: "block"`, which would block the compaction itself, and it is
    /// not one of the events that accept `hookSpecificOutput.additionalContext`. So the brief is
    /// armed here and delivered on the session's next `PostToolUse`, which does accept it and fires
    /// within one tool call of the compacted session resuming.
    private func preCompact(_ event: HookEvent, session: AgentSession, taskId: String?) -> Outcome {
        guard session.role == .worker, let taskId else { return .none }
        awaitingReBrief.insert(session.sessionId)
        let trigger = event.compactTrigger == "manual" ? "manually" : "automatically"
        _ = try? progress.append(
            taskId: taskId, sessionId: session.sessionId, kind: .status,
            text: "Context compacted \(trigger); re-sending the task brief."
        )
        return .none
    }

    private func reBrief(session: AgentSession, taskId: String?, scope: AgentBoardServer.TokenScope) -> String? {
        if scope == .reviewer {
            return (try? ReviewPrompt.postCompactionBrief(db: db, session: session)) ?? nil
        }
        guard let taskId, let task = try? tasks.get(taskId) else { return nil }
        let epic = task.epicId.flatMap { try? epics.get($0) } ?? nil
        let injected = (try? notes.notesForSpawn(
            projectId: task.projectId, taskId: taskId, epicId: task.epicId
        )) ?? SpawnNotes()
        return OpeningPrompt.postCompactionBrief(
            task: task,
            branch: session.branch ?? TaskStore.branchName(for: taskId),
            epicGoal: epic?.goal,
            notes: injected,
            reviewFindings: (try? progress.openReviewFindings(taskId: taskId)) ?? nil,
            comments: (try? CommentStore(db).list(taskId: taskId)) ?? []
        )
    }

    /// `PreCompact` carries the trigger; the `SessionStart` that follows it does not. An unreadable
    /// or missing row reads as manual, because the cost of re-orienting a session that did not need
    /// it is one wasted turn, and the cost of skipping it is a session that sits idle forever.
    private func lastCompactTrigger(sessionId: String) -> String? {
        guard let row = try? hookEvents.mostRecent(sessionId: sessionId, event: "PreCompact"),
              let data = row.payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["trigger"] as? String
    }

    /// `/clear` ends the session and starts a new one under a new id, and the fork payload does not
    /// name its parent. The grant is the only link back, so an unknown session id arriving on a live
    /// grant bound to a known session is the fork signal. The old row keeps its state and its spend —
    /// the fork writes its own transcript, and metering reads transcripts.
    private func adoptFork(newSessionId: String, identity: TokenIdentity) {
        guard let priorId = identity.sessionId, priorId != newSessionId,
              (try? sessions.get(newSessionId)) == nil,
              let prior = try? sessions.get(priorId),
              prior.projectId == identity.projectId,
              prior.role.rawValue == identity.scope.rawValue
        else { return }

        let adopted = AgentSession(
            sessionId: newSessionId,
            shortId: prior.shortId,
            projectId: identity.projectId,
            taskId: prior.taskId,
            role: prior.role,
            worktreePath: prior.worktreePath,
            branch: prior.branch,
            cwd: prior.cwd,
            state: .running,
            attempt: prior.attempt,
            model: prior.model
        )
        guard (try? sessions.insert(adopted)) != nil else { return }

        try? grants.bind(token: identity.token, sessionId: newSessionId)
        if prior.role == .orchestrator {
            try? projects.setOrchestratorSession(identity.projectId, sessionId: newSessionId)
        }
    }

    /// A hook payload names whatever session id it likes, and the grant in the query string decides
    /// the project. Every session lookup here goes through this, so another project's session reads
    /// as absent rather than as one this grant may write to.
    private func projectSession(_ sessionId: String, identity: TokenIdentity) -> AgentSession? {
        guard let session = try? sessions.get(sessionId), session.projectId == identity.projectId else { return nil }
        return session
    }

    /// The tool is about to run, so the session is not idle for however long it takes. Only ever
    /// called on a `PreToolUse` that passed: a denied call never runs and must buy no grace.
    private func beginToolCall(_ event: HookEvent, identity: TokenIdentity, sessionId: String) {
        guard let session = projectSession(sessionId, identity: identity) else { return }
        try? sessions.beginToolCall(session.sessionId, at: .nowMillis, tool: event.toolName)
    }

    private func process(_ event: HookEvent, identity: TokenIdentity) -> Outcome {
        let sessionId = event.sessionId
        _ = try? hookEvents.append(sessionId: sessionId, event: event.name, payload: event.rawJSON)

        if event.name == "PreToolUse" {
            if let violation = IntegrationGuard.violation(
                toolName: event.toolName, command: event.toolCommand, scope: identity.scope
            ) {
                // The deny is decided before any lookup; the row is best-effort so an unrecognized
                // session can never turn a block into a pass.
                let session = projectSession(sessionId, identity: identity)
                if let taskId = session?.taskId ?? identity.taskId {
                    _ = try? progress.append(
                        taskId: taskId,
                        sessionId: session?.sessionId,
                        kind: .error,
                        text: "Blocked \(violation.rawValue): \(event.toolCommand ?? "")"
                    )
                }
                return .deny(.deny(violation.reason(for: identity.scope)))
            }
            let verdict = SharedCheckoutGuard.inspect(toolName: event.toolName, command: event.toolCommand)
            if verdict != .allow, isSharedWorker(identity, sessionId: sessionId),
               let denial = sharedCheckoutDenial(verdict, sessionId: sessionId) {
                if let taskId = (try? sessions.get(sessionId))?.taskId ?? identity.taskId {
                    _ = try? progress.append(
                        taskId: taskId, sessionId: sessionId, kind: .error,
                        text: "Blocked `git \(denial.command)` in the shared checkout: \(event.toolCommand ?? "")"
                    )
                }
                return .deny(.deny(denial.reason))
            }
            if let order = windDownToDeliver(sessionId: sessionId, identity: identity) {
                return .deny(.deny(ShutdownOrder.windDownOrder(reason: order.reason, via: .hook)))
            }
            if FileLockPolicy.locks(toolName: event.toolName), let request = lockRequest(event, identity: identity, sessionId: sessionId) {
                let outcome = claim(request)
                if outcome.lockWait == nil { beginToolCall(event, identity: identity, sessionId: sessionId) }
                return outcome
            }
            beginToolCall(event, identity: identity, sessionId: sessionId)
            return .none
        }

        guard !sessionId.isEmpty else { return .none }

        let known = try? sessions.get(sessionId)
        if let known, known.projectId != identity.projectId { return .none }
        if identity.sessionId == nil {
            try? grants.bind(token: identity.token, sessionId: sessionId)
        }
        adoptFork(newSessionId: sessionId, identity: identity)
        guard let session = projectSession(sessionId, identity: identity) else { return .none }
        let taskId = session.taskId ?? identity.taskId

        switch event.name {
        case "SessionStart":
            try? sessions.setState(sessionId, .running)
            if let path = event.transcriptPath {
                try? sessions.setTranscriptPath(sessionId, path)
            }
            // A compaction keeps the session id and writes no `SessionEnd` (measured, SPEC §2), so
            // nothing is rebound or re-pinned here. A worker's compaction is handled instead by
            // `PreCompact` arming a re-brief that `PostToolUse` delivers.
            if event.sessionSource == "compact", session.role == .orchestrator {
                return .follow([.orchestratorCompacted(
                    projectId: session.projectId,
                    sessionId: sessionId,
                    manual: lastCompactTrigger(sessionId: sessionId) != "auto"
                )])
            }

        case "PostToolUse":
            try? sessions.endToolCall(sessionId, at: .nowMillis, tool: event.toolName)
            if let taskId {
                if let task = try? tasks.get(taskId), task.blocked {
                    try? board.unblock(taskId: taskId, sessionId: sessionId)
                }
                if let tool = event.toolName {
                    _ = try? progress.append(taskId: taskId, sessionId: sessionId, kind: .tool, text: tool)
                }
            }
            if [.starting, .idle, .blocked].contains(session.state) {
                try? sessions.setState(sessionId, .running)
            }
            if awaitingReBrief.remove(sessionId) != nil,
               let brief = reBrief(session: session, taskId: taskId, scope: identity.scope) {
                return .respond(.context(brief))
            }

        case "SubagentStop":
            // A subagent can run for many minutes without the parent making a tool call of its own,
            // so without this the idle clock reads the session as asleep while it is working.
            try? sessions.recordActivity(sessionId, at: .nowMillis, lastTool: session.lastTool)

        case "PreCompact":
            return preCompact(event, session: session, taskId: taskId)

        case "Notification":
            guard let type = event.notificationType else { return .none }
            if Self.blockingNotificationTypes.contains(type) || type.hasPrefix("elicitation") {
                let reason = event.notificationMessage ?? type
                var followUps: [FollowUp] = []
                if let taskId, (try? board.block(taskId: taskId, sessionId: sessionId, reason: reason)) != nil {
                    followUps.append(.reportQueued(projectId: session.projectId))
                } else {
                    // Nothing was marked blocked, so the project's attention signal cannot see this
                    // and will not raise the banner that owns every blocked worker.
                    try? sessions.setState(sessionId, .blocked)
                    followUps.append(
                        .notify(
                            projectId: session.projectId, sessionId: sessionId,
                            title: "Agent needs input", body: reason
                        )
                    )
                }
                return .follow(followUps)
            } else if type == "idle_prompt", session.state.isActive {
                try? sessions.setState(sessionId, .idle)
            }

        case "Stop":
            // The turn is over, so nothing it launched is still running. This is what stops a
            // `PostToolUse` lost to an interrupt from leaving a grace window open behind it.
            try? sessions.clearToolCalls(sessionId)
            if session.role == .orchestrator {
                return .follow([.orchestratorTurnEnded(projectId: session.projectId, sessionId: sessionId)])
            }
            if session.state.isActive {
                try? sessions.setState(sessionId, .idle)
            }
            if let message = event.lastAssistantMessage {
                try? sessions.setStopReason(sessionId, String(message.prefix(200)))
            }

        case "SessionEnd":
            try? sessions.clearToolCalls(sessionId)
            if session.state != .completed && session.state != .failed {
                try? sessions.setState(sessionId, .stopped, endedAt: .nowMillis)
            }
            try? locks.releaseAll(sessionId: sessionId)

        default:
            break
        }
        return .none
    }
}
