import Foundation

/// Lane order on the task board: state first, then recency. Creation order is deliberately not
/// the top-level key — the oldest epic is rarely the one being worked on.
public enum EpicLaneOrder {
    /// The standalone-work lane, pinned above every epic.
    public static let noEpicLaneId = "no-epic"

    public static func precedence(_ state: EpicState) -> Int {
        switch state {
        case .active: 0
        case .planning: 1
        case .integrating: 2
        case .done: 3
        case .abandoned: 4
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
