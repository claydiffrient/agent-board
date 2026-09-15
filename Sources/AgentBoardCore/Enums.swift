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

    /// The epic is over: nothing further is planned into it and it cannot be closed again into the
    /// other terminal state. `done` and `abandoned` mean different things to the human who chose one.
    public var isTerminal: Bool {
        switch self {
        case .done, .abandoned: return true
        case .planning, .active, .integrating: return false
        }
    }
}

public enum SessionState: String, Codable, Sendable, CaseIterable, Equatable, DatabaseValueConvertible {
    /// The worktree exists and the row is written, but no agent process has been launched yet:
    /// the repository is still being prepared. A session here holds a concurrency slot and can do
    /// no work.
    case setup
    case starting
    case running
    case idle
    case blocked
    /// Held at `PreToolUse` because another session in the same shared checkout holds the file this
    /// write is about to touch. Like `setup`, it holds a concurrency slot and can do no work, so the
    /// idle cap and the stall indicator must not read it as a wedge.
    case waitingOnLock = "waiting_on_lock"
    case stopped
    case failed
    case completed

    public var isActive: Bool {
        switch self {
        case .setup, .starting, .running, .idle, .blocked, .waitingOnLock: return true
        case .stopped, .failed, .completed: return false
        }
    }

    /// States in which making no tool call is the design rather than a symptom.
    public var idlesByDesign: Bool {
        switch self {
        case .setup, .blocked, .waitingOnLock: return true
        case .starting, .running, .idle, .stopped, .failed, .completed: return false
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
    case blocked
    case proposal
    case decision
}

public enum ApprovalKind: String, Codable, Sendable, CaseIterable, Equatable, DatabaseValueConvertible {
    case spawn
    case integration
    case push
    case pullRequest = "pull_request"
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
}
