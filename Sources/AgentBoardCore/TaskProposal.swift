import Foundation

/// Why an epic a proposal names is not a destination for it. Checked when the worker proposes, so
/// it learns at once, and again when the proposal is promoted, because an epic can close in
/// between. SPEC §5.
public enum ProposalEpicRefusal: Error, Equatable, Sendable {
    case notFound(String)
    case otherProject(epicId: String)
    /// The `set_epic` rule: adding an unfinished task to a closed epic would make a finished epic
    /// unfinished, and an abandoned one would acquire work nobody intends to do.
    case closed(epicId: String, state: EpicState)

    public var reason: String {
        switch self {
        case .notFound(let id):
            return "Epic \(id) does not exist in this project."
        case .otherProject(let id):
            return "Epic \(id) belongs to another project, and a task never crosses projects."
        case .closed(let id, let state):
            return "Epic \(id) is already \(state.rawValue), so it takes no more tasks: adding an "
                + "unfinished task would make a finished epic unfinished."
        }
    }
}

public struct Promotion: Sendable, Equatable {
    /// Tasks that became `ready` as a side effect of the promotion, the promoted one included.
    public var newlyReady: [String]
    public var landedIn: TaskColumn
    /// Set when the proposal named an epic that stopped being a destination while it waited; the
    /// task promoted into no epic instead.
    public var droppedEpic: ProposalEpicRefusal?

    public init(newlyReady: [String], landedIn: TaskColumn, droppedEpic: ProposalEpicRefusal? = nil) {
        self.newlyReady = newlyReady
        self.landedIn = landedIn
        self.droppedEpic = droppedEpic
    }
}
