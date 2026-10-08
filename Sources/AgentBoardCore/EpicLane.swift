/// A lane's done/total tally, as shown on the epic lane header. A closed task (SPEC §5) is out of
/// the denominator: it is neither work owed nor work done.
public struct EpicTaskCount: Sendable, Equatable {
    public var done: Int
    public var total: Int
    public var closed: Int

    public init(done: Int, total: Int, closed: Int = 0) {
        self.done = done
        self.total = total
        self.closed = closed
    }

    public var label: String {
        let tally = "\(done)/\(total - closed) done"
        return closed == 0 ? tally : "\(tally) · \(closed) closed"
    }

    public var unfinished: Int { total - done - closed }

    /// SPEC §5.2: every task `done` or `closed`, at least one of them `done`.
    public var readyForIntegration: Bool { done > 0 && unfinished == 0 }
}

public enum EpicLaneAction: String, Sendable, Equatable, CaseIterable {
    case requestIntegration
    case openPullRequest
    case closeAsDone
    case abandon

    /// The two that end the epic by hand. The header tucks these behind a menu so the lane never
    /// grows a destructive button next to an ordinary one.
    public var closure: EpicClosure? {
        switch self {
        case .closeAsDone: return .done
        case .abandon: return .abandoned
        case .requestIntegration, .openPullRequest: return nil
        }
    }
}

public enum EpicLane {
    public static func taskCount(columns: some Sequence<TaskColumn>) -> EpicTaskCount {
        var done = 0
        var total = 0
        var closed = 0
        for column in columns {
            total += 1
            if column == .done { done += 1 }
            if column == .closed { closed += 1 }
        }
        return EpicTaskCount(done: done, total: total, closed: closed)
    }

    /// An epic that has not reached a terminal state can always be ended by hand, including one
    /// mid-integration: losing interest during integration is the same human decision as losing it
    /// before. Whether the close actually goes through is `Board.closeEpic`'s call, not this one's —
    /// a live worker in the epic refuses it there.
    public static func actions(state: EpicState, readyForIntegration: Bool) -> [EpicLaneAction] {
        switch state {
        case .planning, .active, .pullRequestOpen:
            return (readyForIntegration ? [.requestIntegration] : []) + [.closeAsDone, .abandon]
        case .integrated:
            return [.openPullRequest, .closeAsDone, .abandon]
        case .integrating:
            return [.closeAsDone, .abandon]
        case .done:
            return [.openPullRequest]
        case .abandoned:
            return []
        }
    }

    /// The lane's state badge. A PR-open epic names its pull request, as a task card's pill does.
    public static func stateLabel(state: EpicState, pullRequest: PullRequestReference?) -> String {
        guard state == .pullRequestOpen else { return state.rawValue }
        return pullRequest.map { "PR #\($0.number) open" } ?? "PR open"
    }
}
