/// A lane's done/total tally, as shown on the epic lane header.
public struct EpicTaskCount: Sendable, Equatable {
    public var done: Int
    public var total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }

    public var label: String { "\(done)/\(total) done" }

    /// Matches `Board.epicReadyForIntegration`: at least one task, all of them in `done`.
    public var readyForIntegration: Bool { total > 0 && done == total }
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
        for column in columns {
            total += 1
            if column == .done { done += 1 }
        }
        return EpicTaskCount(done: done, total: total)
    }

    /// An epic that has not reached a terminal state can always be ended by hand, including one
    /// mid-integration: losing interest during integration is the same human decision as losing it
    /// before. Whether the close actually goes through is `Board.closeEpic`'s call, not this one's —
    /// a live worker in the epic refuses it there.
    public static func actions(state: EpicState, readyForIntegration: Bool) -> [EpicLaneAction] {
        switch state {
        case .planning, .active:
            return (readyForIntegration ? [.requestIntegration] : []) + [.closeAsDone, .abandon]
        case .integrating:
            return [.closeAsDone, .abandon]
        case .done:
            return [.openPullRequest]
        case .abandoned:
            return []
        }
    }
}
