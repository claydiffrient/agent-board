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

    public static func actions(state: EpicState, readyForIntegration: Bool) -> [EpicLaneAction] {
        switch state {
        case .planning, .active:
            return readyForIntegration ? [.requestIntegration] : []
        case .done:
            return [.openPullRequest]
        case .integrating, .abandoned:
            return []
        }
    }
}
