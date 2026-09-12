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
    private let board: Board
    private let events: any BoardEventSink
    private let queue = DispatchQueue(label: "agent-board.hooks")

    public static let blockingNotificationTypes: Set<String> = ["permission_prompt", "agent_needs_input"]

    private enum FollowUp {
        case notify(title: String, body: String)
        case orchestratorTurnEnded(projectId: String, sessionId: String)
        case reportQueued(projectId: String)
    }

    private struct Outcome {
        var followUps: [FollowUp] = []
        var decision: HookDecision?

        static let none = Outcome()
        static func follow(_ followUps: [FollowUp]) -> Outcome { Outcome(followUps: followUps) }
        static func deny(_ decision: HookDecision) -> Outcome { Outcome(decision: decision) }
    }

    public init(db: AppDatabase, events: any BoardEventSink) {
        hookEvents = HookEventStore(db)
        grants = TokenGrantStore(db)
        sessions = SessionStore(db)
        projects = ProjectStore(db)
        tasks = TaskStore(db)
        progress = ProgressStore(db)
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
        return outcome.decision
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

    private func process(_ event: HookEvent, identity: TokenIdentity) -> Outcome {
        let sessionId = event.sessionId
        _ = try? hookEvents.append(sessionId: sessionId, event: event.name, payload: event.rawJSON)

        if event.name == "PreToolUse" {
            guard let violation = IntegrationGuard.violation(toolName: event.toolName, command: event.toolCommand) else {
                return .none
            }
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
            return .deny(.deny(violation.reason))
        }

        guard !sessionId.isEmpty else { return .none }

        if identity.sessionId == nil {
            try? grants.bind(token: identity.token, sessionId: sessionId)
        }
        adoptFork(newSessionId: sessionId, identity: identity)
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

        default:
            break
        }
        return .none
    }
}
