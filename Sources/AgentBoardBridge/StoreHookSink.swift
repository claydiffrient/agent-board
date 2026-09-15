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
    private let notes: NoteStore
    private let epics: EpicStore
    private let board: Board
    private let events: any BoardEventSink
    private let queue = DispatchQueue(label: "agent-board.hooks")
    /// Sessions whose context was just compacted and that have not yet been handed their task back.
    /// Touched only from `queue`. Deliberately not persisted: the re-brief is worth nothing to a
    /// session that has since ended, and Agent Board restarting mid-compaction loses nothing else.
    nonisolated(unsafe) private var awaitingReBrief: Set<String> = []

    public static let blockingNotificationTypes: Set<String> = ["permission_prompt", "agent_needs_input"]

    private enum FollowUp {
        case notify(title: String, body: String)
        case orchestratorTurnEnded(projectId: String, sessionId: String)
        case reportQueued(projectId: String)
        case orchestratorCompacted(projectId: String, sessionId: String, manual: Bool)
    }

    private struct Outcome {
        var followUps: [FollowUp] = []
        var decision: HookDecision?

        static let none = Outcome()
        static func follow(_ followUps: [FollowUp]) -> Outcome { Outcome(followUps: followUps) }
        static func deny(_ decision: HookDecision) -> Outcome { Outcome(decision: decision) }
        static func respond(_ decision: HookDecision, _ followUps: [FollowUp] = []) -> Outcome {
            Outcome(followUps: followUps, decision: decision)
        }
    }

    public init(db: AppDatabase, events: any BoardEventSink) {
        hookEvents = HookEventStore(db)
        grants = TokenGrantStore(db)
        sessions = SessionStore(db)
        tasks = TaskStore(db)
        progress = ProgressStore(db)
        shutdowns = ShutdownOrderStore(db)
        deliveries = ShutdownDeliveryStore(db)
        notes = NoteStore(db)
        epics = EpicStore(db)
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
            case .orchestratorCompacted(let projectId, let sessionId, let manual):
                await events.orchestratorCompacted(projectId: projectId, sessionId: sessionId, manual: manual)
            }
        }
        return outcome.decision
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

    private func reBrief(session: AgentSession, taskId: String?) -> String? {
        guard let taskId, let task = try? tasks.get(taskId) else { return nil }
        let epic = task.epicId.flatMap { try? epics.get($0) } ?? nil
        let injected = (try? notes.notesForSpawn(
            projectId: task.projectId, taskId: taskId, epicId: task.epicId
        )) ?? []
        return OpeningPrompt.postCompactionBrief(
            task: task,
            branch: session.branch ?? TaskStore.branchName(for: taskId),
            epicGoal: epic?.goal,
            notes: injected
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
            if awaitingReBrief.remove(sessionId) != nil, let brief = reBrief(session: session, taskId: taskId) {
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

        default:
            break
        }
        return .none
    }
}
