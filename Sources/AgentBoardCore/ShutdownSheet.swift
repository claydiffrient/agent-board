import Foundation

/// Where one worker stands in a wind-down order, as the progress sheet reads it.
public enum ShutdownRowState: String, Sendable, Equatable, CaseIterable {
    /// Enrolled, but nothing has reached it yet: delivery rides its next `PreToolUse`, and a worker
    /// deep in a turn makes no tool call for a while. Its grace period has not started.
    case ordered
    /// Handed the order and still inside its grace period.
    case closing
    /// Sitting on a permission prompt, so no hook fires and no resume can reach it until a human
    /// answers the prompt. Distinct from silence: this one is fixable in seconds.
    case waitingOnHuman = "waiting_on_human"
    /// Handed the order, and silent for longer than the grace period allows.
    case notResponding = "not_responding"
    /// Answered `acknowledge_shutdown`.
    case acknowledged
    /// The session is gone — killed, crashed, or ended on its own. Nothing more is coming from it.
    case ended

    /// Closed rows are the numerator of "X/Y agents closed". A session that died mid-shutdown is
    /// done, not pending forever.
    public var isClosed: Bool {
        switch self {
        case .acknowledged, .ended: return true
        case .ordered, .closing, .waitingOnHuman, .notResponding: return false
        }
    }

    public var label: String {
        switch self {
        case .ordered: return "ordered"
        case .closing: return "closing"
        case .waitingOnHuman: return "waiting on you"
        case .notResponding: return "not responding"
        case .acknowledged: return "acknowledged"
        case .ended: return "closed"
        }
    }

    /// One line the human can act on, so a row never leaves it guessing what it is looking at.
    public var detail: String {
        switch self {
        case .ordered:
            return "Enrolled. The order reaches it on its next tool call; it has not been told yet."
        case .closing:
            return "Told to wind down. Committing its worktree, then acknowledging."
        case .waitingOnHuman:
            return "Stopped on a permission prompt. Nothing can reach it until you answer. Attach to clear it."
        case .notResponding:
            return "Told to wind down and silent since. Stop it to kill the process outright."
        case .acknowledged:
            return "Committed and acknowledged. Its task is back in ready with a resume note."
        case .ended:
            return "The session ended on its own. Nothing more is coming from it."
        }
    }
}

public struct ShutdownRow: Sendable, Equatable, Identifiable {
    public var sessionId: String
    public var shortId: String?
    public var taskTitle: String?
    public var state: ShutdownRowState
    /// When this row's clock started: delivery for a timed state, enrollment before that.
    public var since: Date
    public var note: String?

    public init(
        sessionId: String, shortId: String?, taskTitle: String?, state: ShutdownRowState,
        since: Date, note: String? = nil
    ) {
        self.sessionId = sessionId
        self.shortId = shortId
        self.taskTitle = taskTitle
        self.state = state
        self.since = since
        self.note = note
    }

    public var id: String { sessionId }
    public var isClosed: Bool { state.isClosed }
    public var displayShortId: String { shortId ?? String(sessionId.prefix(8)) }
}

public struct ShutdownCounts: Sendable, Equatable {
    public var total: Int
    public var closed: Int
    public var notResponding: Int
    public var waitingOnHuman: Int

    public init(total: Int, closed: Int, notResponding: Int = 0, waitingOnHuman: Int = 0) {
        self.total = total
        self.closed = closed
        self.notResponding = notResponding
        self.waitingOnHuman = waitingOnHuman
    }

    public var outstanding: Int { max(0, total - closed) }
    public var isComplete: Bool { closed >= total }

    public var headline: String {
        if total == 0 { return "No workers were running" }
        if isComplete { return "\(closed)/\(total) agents closed" }
        return "Closing \(closed)/\(total) agents"
    }
}

/// The pure half of the shutdown progress sheet: delivery rows plus live sessions plus a clock in,
/// row states and counts out.
public enum ShutdownSheetModel {
    /// The grace period is measured from `deliveredAt`, never from `orderedAt`. A worker that was
    /// enrolled but never handed the order has not failed to answer — it was never asked.
    public static func rowState(
        _ delivery: ShutdownDelivery,
        session: AgentSession?,
        graceSeconds: Int,
        now: Int64
    ) -> ShutdownRowState {
        if delivery.isAcknowledged { return .acknowledged }
        guard let session, session.state.isActive else { return .ended }
        if session.state == .blocked { return .waitingOnHuman }
        guard let deliveredAt = delivery.deliveredAt else { return .ordered }
        return now - deliveredAt >= Int64(graceSeconds) * 1000 ? .notResponding : .closing
    }

    public static func rows(
        deliveries: [ShutdownDelivery],
        sessions: [AgentSession],
        taskTitles: [String: String] = [:],
        graceSeconds: Int,
        now: Int64
    ) -> [ShutdownRow] {
        let bySession = Dictionary(sessions.map { ($0.sessionId, $0) }, uniquingKeysWith: { first, _ in first })
        return deliveries.map { delivery in
            let session = bySession[delivery.sessionId]
            let state = rowState(delivery, session: session, graceSeconds: graceSeconds, now: now)
            return ShutdownRow(
                sessionId: delivery.sessionId,
                shortId: session?.shortId,
                taskTitle: delivery.taskId.flatMap { taskTitles[$0] },
                state: state,
                since: clock(for: state, delivery: delivery, session: session).asDate,
                note: delivery.note
            )
        }
        .sorted { lhs, rhs in
            if lhs.isClosed != rhs.isClosed { return !lhs.isClosed }
            if lhs.state != rhs.state { return lhs.state.rawValue < rhs.state.rawValue }
            return lhs.sessionId < rhs.sessionId
        }
    }

    private static func clock(
        for state: ShutdownRowState, delivery: ShutdownDelivery, session: AgentSession?
    ) -> Int64 {
        switch state {
        case .acknowledged: return delivery.acknowledgedAt ?? delivery.orderedAt
        case .ended: return session?.endedAt ?? delivery.deliveredAt ?? delivery.orderedAt
        case .closing, .notResponding: return delivery.deliveredAt ?? delivery.orderedAt
        case .ordered, .waitingOnHuman: return delivery.orderedAt
        }
    }

    /// `reported` is the supervisor's observable progress, republished on every delivery, every
    /// acknowledgment and every metering tick — reading it is what advances the sheet without a
    /// polling loop. The closed count comes from the rows, which also close out a session that died
    /// on its own; `reported.acknowledged` would leave that one pending forever.
    public static func counts(rows: [ShutdownRow], reported: ShutdownProgress? = nil) -> ShutdownCounts {
        ShutdownCounts(
            total: max(reported?.total ?? 0, rows.count),
            closed: rows.filter(\.isClosed).count,
            notResponding: rows.filter { $0.state == .notResponding }.count,
            waitingOnHuman: rows.filter { $0.state == .waitingOnHuman }.count
        )
    }
}
