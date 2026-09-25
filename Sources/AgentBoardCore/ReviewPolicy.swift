import Foundation
import GRDB

extension RosterAgent {
    /// A guess from free-text `role` ("reviewer", "Code Reviewer"), used only when a project names
    /// no `reviewAgent`. Any rostered agent can review when named, whatever its role says.
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
            return try agentRouting(db, projectId: task.projectId)
        }
    }

    /// Where agent review sends this project's tasks: the named reviewer, else the first usable
    /// agent whose role marks it a reviewer. Status shows this under the `agent` level (SPEC §10).
    public static func agentRouting(_ db: Database, projectId: String) throws -> ReviewRouting {
        if let named = try Project.fetchOne(db, key: projectId)?.settings.reviewAgent {
            return try namedReviewerRouting(db, named: named, projectId: projectId)
        }
        let reviewers = try RosterStore.agents(db, forProject: projectId, enabledOnly: true)
            .filter(\.isReviewer)
        guard let reviewer = reviewers.first else {
            return .humanReview(reason: "Agent review, but this project has no rostered agent with a "
                + "reviewer role, so it needs a person.")
        }
        return .agentReview(agentId: reviewer.id, agentName: reviewer.name)
    }

    /// A named reviewer that cannot take the task sends it to a person, never to another agent
    /// (SPEC §4, §5): the project chose this one, and a silent substitute is what naming it prevents.
    private static func namedReviewerRouting(
        _ db: Database, named: ReviewAgentChoice, projectId: String
    ) throws -> ReviewRouting {
        guard let agent = try RosterAgent.fetchOne(db, key: named.id) else {
            return .humanReview(reason: "Agent review names \(named.name) as this project's reviewer, but "
                + "\(named.name) is no longer on the roster, so it needs a person. Choose another reviewer "
                + "in Project Settings.")
        }
        let optedIn = try RosterStore.agents(db, forProject: projectId, enabledOnly: false)
            .contains { $0.id == agent.id }
        guard optedIn else {
            return .humanReview(reason: "Agent review names \(agent.name) as this project's reviewer, but "
                + "this project no longer uses \(agent.name), so it needs a person. Turn \(agent.name) back "
                + "on in the project's roster, or choose another reviewer.")
        }
        guard agent.enabled else {
            return .humanReview(reason: "Agent review names \(agent.name) as this project's reviewer, but "
                + "\(agent.name) is disabled in the roster, so it needs a person. Enable \(agent.name), or "
                + "choose another reviewer in Project Settings.")
        }
        return .agentReview(agentId: agent.id, agentName: agent.name)
    }
}

/// Who moved a task into `done`. Carried through the acceptance path so the `decision` report names
/// the acceptor rather than always claiming a human.
public enum TaskAcceptance: Sendable, Equatable {
    case human
    /// Completion under no-review or epic review: nobody looked, and the report says so.
    case policy(ReviewLevel)
    /// `sessionId` is the reviewer's own session, which the acceptance must not stop mid-call.
    case reviewer(name: String, verdict: String, sessionId: String? = nil)

    public var describedActor: String {
        switch self {
        case .human: return "a human"
        case .policy(let level): return "the \(level.label.lowercased()) setting, with no review"
        case .reviewer(let name, _, _): return "rostered reviewer \(name)"
        }
    }

    public var acceptingSessionId: String? {
        guard case .reviewer(_, _, let sessionId) = self else { return nil }
        return sessionId
    }

    public var actor: BoardActor {
        switch self {
        case .human: return .human
        case .policy(let level): return .policy(level)
        case .reviewer(let name, _, _): return .reviewer(name: name)
        }
    }
}
