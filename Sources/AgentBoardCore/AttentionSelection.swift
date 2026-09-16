import Foundation

public enum AttentionKind: String, Sendable, Equatable, CaseIterable {
    /// A `Notification` hook reported the worker is waiting on a human (SPEC §7).
    case blocked
    /// No hook has fired for long enough that the worker is probably wedged — a suspicion, not a report.
    case stalled
}

public struct AttentionItem: Sendable, Equatable, Identifiable {
    public var task: BoardTask
    public var session: AgentSession?
    public var kind: AttentionKind
    public var reason: String?
    public var since: Date

    public init(task: BoardTask, session: AgentSession?, kind: AttentionKind, reason: String?, since: Date) {
        self.task = task
        self.session = session
        self.kind = kind
        self.reason = reason
        self.since = since
    }

    public var id: String { task.id }
}

/// What the orchestrator's "Blocked" section shows: workers that have stopped making progress,
/// either because they said so or because they stopped moving.
public enum AttentionSelection {
    /// A running worker whose activity clock has not moved for `threshold` of *awake* time. A
    /// session that has never recorded activity is measured from its start, matching `CapEvaluator`
    /// — including its clock: a suspended worker is not stalled, it is asleep.
    public static func isStalled(
        lastActivity: Date?,
        startedAt: Date,
        awake: AwakeElapsed,
        threshold: TimeInterval
    ) -> Bool {
        guard threshold > 0 else { return false }
        return awake.secondsAwake(since: lastActivity ?? startedAt) >= threshold
    }

    /// Blocked tasks first, then suspected stalls, each longest-waiting first.
    public static func needingAttention(
        tasks: [BoardTask],
        sessions: [AgentSession],
        awake: AwakeElapsed,
        stallThreshold: TimeInterval
    ) -> [AttentionItem] {
        let active = activeWorkerSessionsByTask(sessions)
        var items: [AttentionItem] = []
        var claimed: Set<String> = []

        for task in tasks where task.blocked {
            items.append(
                AttentionItem(
                    task: task,
                    session: active[task.id],
                    kind: .blocked,
                    reason: task.blockedReason,
                    // `blocked` is the last thing written to the row, so `updated_at` is when it was set.
                    since: task.updatedDate
                )
            )
            claimed.insert(task.id)
        }

        for task in tasks where !claimed.contains(task.id) {
            guard let session = active[task.id], session.state == .running else { continue }
            guard isStalled(
                lastActivity: session.lastActivityDate,
                startedAt: session.startedDate,
                awake: awake,
                threshold: stallThreshold
            ) else { continue }
            items.append(
                AttentionItem(
                    task: task,
                    session: session,
                    kind: .stalled,
                    reason: nil,
                    since: session.lastActivityDate ?? session.startedDate
                )
            )
        }

        return items.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind == .blocked }
            if lhs.since != rhs.since { return lhs.since < rhs.since }
            return lhs.task.id < rhs.task.id
        }
    }

    /// The newest still-running session per task; a retry hides the attempt it replaced.
    public static func activeWorkerSessionsByTask(_ sessions: [AgentSession]) -> [String: AgentSession] {
        var result: [String: AgentSession] = [:]
        for session in sessions where session.role == .worker && session.state.isActive {
            guard let taskId = session.taskId else { continue }
            if let existing = result[taskId], existing.startedAt >= session.startedAt { continue }
            result[taskId] = session
        }
        return result
    }
}
