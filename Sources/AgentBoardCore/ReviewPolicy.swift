import Foundation
import GRDB

extension RosterAgent {
    /// `role` is free text (the roster is user-defined), so a reviewer is anything whose role reads
    /// as one: "reviewer", "code reviewer", "Reviewer".
    public var isReviewer: Bool {
        role.lowercased().contains("review")
    }
}

extension RosterStore {
    /// The project's usable agents whose role marks them reviewers, in the project's preference order.
    public func reviewers(forProject projectId: String) throws -> [RosterAgent] {
        try usableAgents(forProject: projectId).filter(\.isReviewer)
    }
}

/// Where a completed task goes, and why. `Board.complete` resolves one of these and routes to it.
public enum ReviewRouting: Sendable, Equatable {
    /// Straight to `done`, through the same acceptance path a human Accept runs.
    case autoAccept
    /// Into `review`, held by this rostered reviewer.
    case agentReview(agentId: String, agentName: String)
    /// Into `review`, waiting on a person. `reason` is non-nil when a narrower level asked for an
    /// agent that was not there, so the task card can say why it is sitting on a human.
    case humanReview(reason: String?)
}

public enum ReviewPolicy {
    /// The level in force for a task: its epic's override if it has one, otherwise the project's.
    public static func level(_ db: Database, task: Task) throws -> ReviewLevel {
        if let epicId = task.epicId, let override = try Epic.fetchOne(db, key: epicId)?.reviewLevel {
            return override
        }
        guard let project = try Project.fetchOne(db, key: task.projectId) else { return .task }
        return project.settings.reviewLevel
    }

    public static func routing(_ db: Database, task: Task) throws -> ReviewRouting {
        // An epic's integration task is the human's own gate (SPEC §5.2): never auto-accepted, never
        // handed to an agent, at any level.
        if task.origin == .integration { return .humanReview(reason: nil) }
        switch try level(db, task: task) {
        case .none:
            return .autoAccept
        case .task:
            return .humanReview(reason: nil)
        case .epic:
            guard task.epicId != nil else {
                return .humanReview(reason: "Epic review, but this task belongs to no epic, so there is no "
                    + "integration gate to review it at.")
            }
            return .autoAccept
        case .agent:
            let reviewers = try RosterStore.agents(db, forProject: task.projectId, enabledOnly: true)
                .filter(\.isReviewer)
            guard let reviewer = reviewers.first else {
                return .humanReview(reason: "Agent review, but this project has no rostered agent with a "
                    + "reviewer role, so it needs a person.")
            }
            return .agentReview(agentId: reviewer.id, agentName: reviewer.name)
        }
    }
}

/// Who moved a task into `done`. Carried through the acceptance path so the `decision` report names
/// the acceptor rather than always claiming a human.
public enum TaskAcceptance: Sendable, Equatable {
    case human
    /// Completion under no-review or epic review: nobody looked, and the report says so.
    case policy(ReviewLevel)
    case reviewer(name: String, verdict: String)

    public var describedActor: String {
        switch self {
        case .human: return "a human"
        case .policy(let level): return "the \(level.label.lowercased()) setting, with no review"
        case .reviewer(let name, _): return "rostered reviewer \(name)"
        }
    }
}
