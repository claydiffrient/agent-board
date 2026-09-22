import Foundation

/// A rostered agent mid-task, as the lifecycle reports it. The roster screen shows it as a badge
/// and the delete guard reads it to refuse.
public struct RosterAssignment: Sendable, Equatable, Identifiable {
    public var agentId: String
    public var taskId: String
    public var taskTitle: String
    public var projectName: String?

    public var id: String { agentId }

    public init(agentId: String, taskId: String, taskTitle: String, projectName: String? = nil) {
        self.agentId = agentId
        self.taskId = taskId
        self.taskTitle = taskTitle
        self.projectName = projectName
    }
}

public struct RosterListEntry: Sendable, Equatable, Identifiable {
    public var agent: RosterAgent
    public var assignment: RosterAssignment?

    public var id: String { agent.id }
    public var isWorking: Bool { assignment != nil }

    public init(agent: RosterAgent, assignment: RosterAssignment? = nil) {
        self.agent = agent
        self.assignment = assignment
    }
}

/// What happens if the roster screen deletes this agent right now.
public enum RosterDeleteDecision: Sendable, Equatable {
    case allowed
    /// The agent is mid-task; deleting would orphan the session, so the screen refuses.
    case refused(taskTitle: String)

    public var isAllowed: Bool { self == .allowed }
}

public enum RosterListing {
    /// Display order for the roster screen: usable agents first, then name, then id. Deliberately
    /// not the store's order, which sorts by name alone.
    public static func ordered(_ agents: [RosterAgent]) -> [RosterAgent] {
        agents.sorted { lhs, rhs in
            if lhs.enabled != rhs.enabled { return lhs.enabled }
            let byName = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return lhs.id < rhs.id
        }
    }

    public static func entries(
        agents: [RosterAgent], assignments: [RosterAssignment]
    ) -> [RosterListEntry] {
        let byAgent = Dictionary(assignments.map { ($0.agentId, $0) }, uniquingKeysWith: { first, _ in first })
        return ordered(agents).map { RosterListEntry(agent: $0, assignment: byAgent[$0.id]) }
    }

    /// Splits the whole roster by whether this project has opted the agent in. Both halves keep
    /// display order, and ids the project selected that are no longer in the roster fall away.
    public static func partition(
        roster: [RosterAgent], selectedIds: some Sequence<String>
    ) -> (selected: [RosterAgent], available: [RosterAgent]) {
        let selected = Set(selectedIds)
        let ordered = ordered(roster)
        return (ordered.filter { selected.contains($0.id) }, ordered.filter { !selected.contains($0.id) })
    }

    public static func deleteDecision(for entry: RosterListEntry) -> RosterDeleteDecision {
        guard let assignment = entry.assignment else { return .allowed }
        return .refused(taskTitle: assignment.taskTitle)
    }
}
