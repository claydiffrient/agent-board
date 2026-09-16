import GRDB

public enum TaskColumn: String, Codable, Sendable, CaseIterable, Equatable, DatabaseValueConvertible {
    case proposed
    case backlog
    case ready
    case running
    case review
    case done

    public var index: Int { Self.allCases.firstIndex(of: self)! }

    public var next: TaskColumn? {
        let all = Self.allCases
        let i = index + 1
        return i < all.count ? all[i] : nil
    }

    public var previous: TaskColumn? {
        let i = index - 1
        return i >= 0 ? Self.allCases[i] : nil
    }

    static var orderingSQL: String {
        let whens = allCases.map { "WHEN '\($0.rawValue)' THEN \($0.index)" }.joined(separator: " ")
        return "CASE column_name \(whens) ELSE \(allCases.count) END"
    }
}

public enum EpicState: String, Codable, Sendable, CaseIterable, Equatable, DatabaseValueConvertible {
    case planning
    case active
    case integrating
    case done
    case abandoned
}

public enum SessionState: String, Codable, Sendable, CaseIterable, Equatable, DatabaseValueConvertible {
    case starting
    case running
    case idle
    case blocked
    case stopped
    case failed
    case completed

    public var isActive: Bool {
        switch self {
        case .starting, .running, .idle, .blocked: return true
        case .stopped, .failed, .completed: return false
        }
    }

    public static var activeStates: [SessionState] { allCases.filter(\.isActive) }
}

public enum SessionRole: String, Codable, Sendable, CaseIterable, Equatable, DatabaseValueConvertible {
    case orchestrator
    case worker
}

public enum TaskOrigin: String, Codable, Sendable, CaseIterable, Equatable, DatabaseValueConvertible {
    case human
    case orchestrator
    case workerProposal = "worker_proposal"
    /// The synthetic task an epic's integrator worker is bound to (§5.2 step 3).
    case integration
}

public enum ReportKind: String, Codable, Sendable, CaseIterable, Equatable, DatabaseValueConvertible {
    case complete
    case failed
    /// A rostered agent did its portion and returned the task to the queue for the next one.
    case handoff
    case blocked
    case proposal
    case decision
}

public enum ApprovalKind: String, Codable, Sendable, CaseIterable, Equatable, DatabaseValueConvertible {
    case spawn
    case integration
}

public enum ApprovalResolution: String, Codable, Sendable, CaseIterable, Equatable, DatabaseValueConvertible {
    case approved
    case denied
}

public enum ProgressKind: String, Codable, Sendable, CaseIterable, Equatable, DatabaseValueConvertible {
    case note
    case status
    case error
    case tool
}

public enum TokenScope: String, Codable, Sendable, CaseIterable, Equatable, DatabaseValueConvertible {
    case orchestrator
    case worker
    /// A rostered reviewer under agent review: it may move its one task out of `review` and nothing else.
    case reviewer
}

/// How much human acceptance a finished task needs before it reaches `done`.
public enum ReviewLevel: String, Codable, Sendable, CaseIterable, Equatable, DatabaseValueConvertible {
    /// Completion goes straight to `done`, running the same side effects a human accept runs.
    case none
    /// A rostered agent whose role marks it a reviewer holds the review column.
    case agent
    /// A human accepts every task. The default, and the behaviour before this setting existed.
    case task
    /// A task inside an epic is accepted on completion; the human's gate is the epic's integration
    /// approval instead. A task with no epic has no such gate, so it falls back to `task`.
    case epic

    public var label: String {
        switch self {
        case .none: return "No review"
        case .agent: return "Agent review"
        case .task: return "Task review"
        case .epic: return "Epic review"
        }
    }
}
