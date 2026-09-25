import Foundation

/// Who asked Agent Board to act, so a report names them instead of always claiming a human.
public enum BoardActor: Sendable, Equatable {
    case human
    case orchestrator(sessionId: String?)
    case reviewer(name: String)
    case policy(ReviewLevel)

    public var described: String {
        switch self {
        case .human: return "a human"
        case .orchestrator: return "the orchestrator"
        case .reviewer(let name): return "rostered reviewer \(name)"
        case .policy(let level): return "the \(level.label.lowercased()) setting"
        }
    }

    /// What a report's "Closed by:" line records.
    public var recorded: String {
        switch self {
        case .human: return "human"
        case .orchestrator(let sessionId): return sessionId ?? "orchestrator"
        case .reviewer(let name): return name
        case .policy(let level): return level.label
        }
    }
}
