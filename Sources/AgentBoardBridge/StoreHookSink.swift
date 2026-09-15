import AgentBoardCore
import AgentBoardServer
import Foundation

public final class StoreHookSink: HookSink {
    private let hookEvents: HookEventStore
    private let grants: TokenGrantStore
    private let sessions: SessionStore
    private let tasks: TaskStore
    private let progress: ProgressStore
    private let shutdowns: ShutdownOrderStore
    private let deliveries: ShutdownDeliveryStore
    private let locks: FileLockStore
    private let projectStore: ProjectStore
    private let waitPolicy: FileLockWaitPolicy
    private let board: Board
    private let events: any BoardEventSink
    private let queue = DispatchQueue(label: "agent-board.hooks")

    public static let blockingNotificationTypes: Set<String> = ["permission_prompt", "agent_needs_input"]

    private enum FollowUp {
        case notify(title: String, body: String)
        case orchestratorTurnEnded(projectId: String, sessionId: String)
        case reportQueued(projectId: String)
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
        static func wait(_ wait: LockWait) -> Outcome { Outcome(lockWait: wait) }
    }

    public init(db: AppDatabase, events: any BoardEventSink, lockWait: FileLockWaitPolicy = .default) {
        hookEvents = HookEventStore(db)
        grants = TokenGrantStore(db)
        sessions = SessionStore(db)
        tasks = TaskStore(db)
        progress = ProgressStore(db)
        shutdowns = ShutdownOrderStore(db)
        deliveries = ShutdownDeliveryStore(db)
        locks = FileLockStore(db)
        projectStore = ProjectStore(db)
        waitPolicy = lockWait
        board = Board(db)
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
            case .notify(let title, let body):
                await events.notify(title: title, body: body)
            case .orchestratorTurnEnded(let projectId, let sessionId):
                await events.orchestratorTurnEnded(projectId: projectId, sessionId: sessionId)
            case .reportQueued(let projectId):
                await events.reportQueued(projectId: projectId)
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
        guard let project = try? projectStore.get(session.projectId) else { return nil }
        guard let path = FileLockPolicy.key(filePath: event.toolFilePath, repoPath: project.repoPath)
        else { return nil }
        return LockWait(
            projectId: session.projectId, path: path, sessionId: sessionId,
            taskId: session.taskId ?? identity.taskId,
            holder: FileLock(projectId: session.projectId, path: path, sessionId: sessionId)
        )
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
            try? sessions.recordActivity(wait.sessionId, at: .nowMillis, lastTool: nil)
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
        let taskId = (try? sessions.get(sessionId))?.taskId ?? identity.taskId
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

    private func process(_ event: HookEvent, identity: TokenIdentity) -> Outcome {
        let sessionId = event.sessionId
        _ = try? hookEvents.append(sessionId: sessionId, event: event.name, payload: event.rawJSON)

        if event.name == "PreToolUse" {
            if let violation = IntegrationGuard.violation(
                toolName: event.toolName, command: event.toolCommand, scope: identity.scope
            ) {
                // The deny is decided before any lookup; the row is best-effort so an unrecognized
                // session can never turn a block into a pass.
                let session = try? sessions.get(sessionId)
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
            if let order = windDownToDeliver(sessionId: sessionId, identity: identity) {
                return .deny(.deny(ShutdownOrder.windDownOrder(reason: order.reason, via: .hook)))
            }
            if FileLockPolicy.locks(toolName: event.toolName), let request = lockRequest(event, identity: identity, sessionId: sessionId) {
                return claim(request)
            }
            return .none
        }

        guard !sessionId.isEmpty else { return .none }

        if identity.sessionId == nil {
            try? grants.bind(token: identity.token, sessionId: sessionId)
        }
        guard let session = try? sessions.get(sessionId) else { return .none }
        let taskId = session.taskId ?? identity.taskId

        switch event.name {
        case "SessionStart":
            try? sessions.setState(sessionId, .running)
            if let path = event.transcriptPath {
                try? sessions.setTranscriptPath(sessionId, path)
            }

        case "PostToolUse":
            try? sessions.recordActivity(sessionId, at: .nowMillis, lastTool: event.toolName)
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

        case "Notification":
            guard let type = event.notificationType else { return .none }
            if Self.blockingNotificationTypes.contains(type) || type.hasPrefix("elicitation") {
                let reason = event.notificationMessage ?? type
                var followUps: [FollowUp] = [.notify(title: "Agent needs input", body: reason)]
                if let taskId {
                    if (try? board.block(taskId: taskId, sessionId: sessionId, reason: reason)) != nil {
                        followUps.append(.reportQueued(projectId: session.projectId))
                    }
                } else {
                    try? sessions.setState(sessionId, .blocked)
                }
                return .follow(followUps)
            } else if type == "idle_prompt", session.state.isActive {
                try? sessions.setState(sessionId, .idle)
            }

        case "Stop":
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
