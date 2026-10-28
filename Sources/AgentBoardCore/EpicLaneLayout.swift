import Foundation

/// Lane order on the task board: state first, then recency. Creation order is deliberately not
/// the top-level key — the oldest epic is rarely the one being worked on.
public enum EpicLaneOrder {
    /// The standalone-work lane, pinned above every epic.
    public static let noEpicLaneId = "no-epic"

    public static func precedence(_ state: EpicState) -> Int {
        switch state {
        case .active: 0
        case .integrated: 1
        case .pullRequestOpen: 2
        case .planning: 3
        case .integrating: 4
        case .done: 5
        case .abandoned: 6
        }
    }

    public static func sorted(_ epics: [Epic]) -> [Epic] {
        epics.sorted { lhs, rhs in
            let left = precedence(lhs.state)
            let right = precedence(rhs.state)
            if left != right { return left < right }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id < rhs.id
        }
    }

    /// Lane ids top to bottom, with the standalone-work lane always first.
    public static func laneOrder(_ epics: [Epic]) -> [String] {
        [noEpicLaneId] + sorted(epics).map(\.id)
    }
}

/// Whether a lane renders collapsed. A done epic defaults collapsed — its work is finished and its
/// tasks may already be archived away — but the human's own choice always wins.
public enum EpicLaneCollapse {
    public static func defaultsCollapsed(state: EpicState) -> Bool { state == .done }

    public static func isCollapsed(state: EpicState, userChoice: Bool?) -> Bool {
        userChoice ?? defaultsCollapsed(state: state)
    }

    public static func defaultsKey(epicId: String) -> String { "epicLaneCollapsed.\(epicId)" }
}

/// Whether an epic gets a lane at all (SPEC §10). A finished epic leaves the board once every task
/// of it is archived; Show Archived brings it back. Unfinished epics always keep theirs, even empty.
public enum EpicLaneVisibility {
    public static func isShown(state: EpicState, archived: some Sequence<Bool>, showArchived: Bool) -> Bool {
        showArchived || !state.isTerminal || archived.contains(false)
    }

    /// What the lane header's Archive action would archive: exactly the rows `ArchiveSweep.archiveEpic`
    /// stamps, so the button is never offered for a click that archives nothing.
    public static func archivable(state: EpicState, tasks: some Sequence<BoardTask>) -> [BoardTask] {
        state == .done ? tasks.filter(ArchiveSweep.isSweepable) : []
    }
}

/// Per-viewer collapse state. `UserDefaults` on purpose: this is a view preference, not board state,
/// and must never reach the database.
public struct EpicCollapseStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func userChoice(epicId: String) -> Bool? {
        defaults.object(forKey: EpicLaneCollapse.defaultsKey(epicId: epicId)) as? Bool
    }

    public func setUserChoice(_ collapsed: Bool, epicId: String) {
        defaults.set(collapsed, forKey: EpicLaneCollapse.defaultsKey(epicId: epicId))
    }

    public func clearUserChoice(epicId: String) {
        defaults.removeObject(forKey: EpicLaneCollapse.defaultsKey(epicId: epicId))
    }

    public func isCollapsed(_ epic: Epic) -> Bool {
        EpicLaneCollapse.isCollapsed(state: epic.state, userChoice: userChoice(epicId: epic.id))
    }
}

/// The jump rail's entries, top to bottom, each carrying the lane id its tap must scroll to. The
/// rail and the board read lane ids from here so a tap can never target an id the board never set.
public enum EpicJumpRail {
    public static let noEpicTitle = "No epic"

    public struct Entry: Sendable, Equatable, Identifiable {
        public let laneId: String
        public let title: String
        public let epicId: String?

        public var id: String { laneId }

        public init(laneId: String, title: String, epicId: String?) {
            self.laneId = laneId
            self.title = title
            self.epicId = epicId
        }
    }

    public static func laneId(forEpicId epicId: String?) -> String {
        epicId ?? EpicLaneOrder.noEpicLaneId
    }

    public static func entries(_ epics: [Epic]) -> [Entry] {
        [Entry(laneId: EpicLaneOrder.noEpicLaneId, title: noEpicTitle, epicId: nil)]
            + EpicLaneOrder.sorted(epics).map {
                Entry(laneId: laneId(forEpicId: $0.id), title: $0.title, epicId: $0.id)
            }
    }
}
