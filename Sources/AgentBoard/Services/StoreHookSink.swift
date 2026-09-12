import AgentBoardCore
import AgentBoardServer
import Foundation

final class StoreHookSink: HookSink {
    private let hookEvents: HookEventStore
    private let grants: TokenGrantStore
    private let sessions: SessionStore
    private let tasks: TaskStore
    private let progress: ProgressStore
    private let board: Board
    private let queue = DispatchQueue(label: "agent-board.hooks")

    static let blockingNotificationTypes: Set<String> = ["permission_prompt", "agent_needs_input"]

    init(db: AppDatabase) {
        hookEvents = HookEventStore(db)
        grants = TokenGrantStore(db)
        sessions = SessionStore(db)
        tasks = TaskStore(db)
        progress = ProgressStore(db)
        board = Board(db)
    }

    func handle(_ event: HookEvent, identity: TokenIdentity) async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.process(event, identity: identity)
                continuation.resume()
            }
        }
    }

    private func process(_ event: HookEvent, identity: TokenIdentity) {
        let sessionId = event.sessionId
        _ = try? hookEvents.append(sessionId: sessionId, event: event.name, payload: event.rawJSON)
        guard !sessionId.isEmpty else { return }

        if identity.sessionId == nil {
            try? grants.bind(token: identity.token, sessionId: sessionId)
        }
        guard let session = try? sessions.get(sessionId) else { return }
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
            guard let type = event.notificationType else { return }
            if Self.blockingNotificationTypes.contains(type) || type.hasPrefix("elicitation") {
                let reason = event.notificationMessage ?? type
                if let taskId {
                    _ = try? board.block(taskId: taskId, sessionId: sessionId, reason: reason)
                } else {
                    try? sessions.setState(sessionId, .blocked)
                }
                MacNotifier.post(title: "Agent needs input", body: reason)
            } else if type == "idle_prompt", session.state.isActive {
                try? sessions.setState(sessionId, .idle)
            }

        case "Stop":
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
    }
}
