import AgentBoardCore

/// Who on the roster is mid-task. Behind a protocol so a render test can mount the screen with a
/// fixed answer rather than a database holding live sessions.
@MainActor
protocol RosterActivityReporting {
    func assignments() -> [RosterAssignment]
}

struct NoRosterActivity: RosterActivityReporting {
    func assignments() -> [RosterAssignment] { [] }
}

struct LiveRosterActivity: RosterActivityReporting {
    let db: AppDatabase

    func assignments() -> [RosterAssignment] {
        (try? RosterStore(db).assignments()) ?? []
    }
}
