import AgentBoardCore

/// Who on the roster is mid-task. The session-to-roster-agent binding belongs to the lifecycle
/// work; until that lands nothing reports an assignment and every agent reads as idle.
@MainActor
protocol RosterActivityReporting {
    func assignments() -> [RosterAssignment]
}

struct NoRosterActivity: RosterActivityReporting {
    func assignments() -> [RosterAssignment] { [] }
}
