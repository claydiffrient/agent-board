import Foundation

/// The paths a shared-checkout session is allowed to commit.
///
/// The lock store is the source of truth rather than the agent's memory of what it edited: a write
/// tool cannot run in a shared checkout without first claiming its file, and a lock is held until
/// the session ends, so the claims are exactly the set of files this session has written. An agent
/// asked to list its own paths would sooner or later name a sibling's.
public enum CommitScope {
    public static func paths(_ locks: [FileLock], sessionId: String) -> [String] {
        Array(Set(locks.filter { $0.sessionId == sessionId }.map(\.path))).sorted()
    }
}

public struct ScopedCommitRequest: Sendable, Equatable {
    public var repoPath: String
    public var branch: String
    public var taskId: String
    /// Repo-relative and already scoped; the runner passes these to git as a pathspec and never
    /// widens them.
    public var paths: [String]
    /// The agent's message, with the attribution trailer already on it.
    public var message: String

    public init(repoPath: String, branch: String, taskId: String, paths: [String], message: String) {
        self.repoPath = repoPath
        self.branch = branch
        self.taskId = taskId
        self.paths = paths
        self.message = message
    }
}

public enum ScopedCommitOutcome: Sendable, Equatable {
    case committed(sha: String, paths: [String])
    /// The paths were claimed but hold no change git would record — an edit that was reverted, or
    /// work already committed.
    case nothingToCommit(paths: [String])
}

/// Runs a scoped commit. Implemented in AgentBoardRuntime, where git lives; declared here so the
/// MCP tool handler can take it without the bridge depending on the runtime.
public protocol ScopedCommitting: Sendable {
    func commit(_ request: ScopedCommitRequest) async throws -> ScopedCommitOutcome
}

public enum ScopedCommitError: Error, CustomStringConvertible, Equatable {
    case noPathsHeld
    case git(String)

    public var description: String {
        switch self {
        case .noPathsHeld:
            return "This session has not written any file in the shared checkout, so there is nothing "
                + "of yours to commit. Edit the files your task needs first."
        case .git(let detail):
            return detail
        }
    }
}
