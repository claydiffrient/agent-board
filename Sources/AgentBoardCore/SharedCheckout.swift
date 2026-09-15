import Foundation

/// Whether a spawned worker gets its own git worktree or runs in the project's own checkout.
public enum WorktreeStrategy: String, Codable, Sendable, CaseIterable, Equatable {
    /// One worktree per task. The default, so no project changes behaviour on upgrade.
    case worktree
    /// Co-resident in the project's checkout on one shared branch, worktree when that is not possible.
    case shared
    /// Share only when a compatible group already holds the checkout and has room.
    case auto

    public var title: String {
        switch self {
        case .worktree: return "Worktree per task"
        case .shared: return "Shared checkout"
        case .auto: return "Auto"
        }
    }
}

/// Where a spawn puts its worker.
public enum WorkerPlacement: Sendable, Equatable {
    case worktree
    /// The project's own checkout, on the group's shared branch.
    case shared(branch: String)

    public var sharedBranch: String? {
        if case .shared(let branch) = self { return branch }
        return nil
    }
}

/// The co-resident tasks running in a project's own checkout on one branch.
///
/// The group is recorded as the session rows themselves: an active worker session with no
/// `worktree_path` is a member, and its `branch` is the group's branch. Nothing else has to be
/// persisted, and a detached `claude --bg` worker that outlives the app is still found on the next
/// launch, because its row is still in the database.
public struct SharedCheckoutGroup: Sendable, Equatable {
    /// One agent at a time in the checkout. Two co-resident agents would overwrite each other's
    /// edits until per-file locking lands; raising this belongs to that change.
    public static let maxMembers = 1

    public static let branchPrefix = "agentboard/shared"

    public var branch: String
    public var memberSessionIds: [String]

    public init(branch: String, memberSessionIds: [String]) {
        self.branch = branch
        self.memberSessionIds = memberSessionIds
    }

    public var isFull: Bool { memberSessionIds.count >= Self.maxMembers }

    /// A shared branch is cut once from one base, so its name carries that base's identity: every
    /// member is in the same epic, or in no epic at all. A task whose base differs asks for a
    /// different branch name here and therefore never joins.
    public static func branch(epicId: String?) -> String {
        guard let epicId else { return branchPrefix }
        return "\(branchPrefix)-epic-\(epicId)"
    }

    /// The group holding `projectId`'s checkout, or nil when no worker is in it.
    public static func current(db: AppDatabase, projectId: String) throws -> SharedCheckoutGroup? {
        let members = try SessionStore(db).active(projectId: projectId)
            .filter { $0.role == .worker && $0.worktreePath == nil }
        guard let branch = members.first?.branch else { return nil }
        return SharedCheckoutGroup(branch: branch, memberSessionIds: members.map(\.sessionId))
    }

    /// Whether a task wanting `wanted` can join this group: same branch means same base, and the
    /// group must still have room under `maxMembers`.
    public func admits(_ wanted: String) -> Bool {
        branch == wanted && !isFull
    }
}

public enum WorkerPlacementDecision {
    /// A full or incompatible group sends the task to a worktree rather than making it wait: spawn
    /// is a synchronous call with no queue behind it, and a task that silently never starts is
    /// worse than one that starts isolated.
    public static func decide(
        strategy: WorktreeStrategy,
        wantedSharedBranch: String,
        group: SharedCheckoutGroup?
    ) -> WorkerPlacement {
        switch strategy {
        case .worktree:
            return .worktree
        case .shared:
            guard let group else { return .shared(branch: wantedSharedBranch) }
            return group.admits(wantedSharedBranch) ? .shared(branch: group.branch) : .worktree
        case .auto:
            guard let group, group.admits(wantedSharedBranch) else { return .worktree }
            return .shared(branch: group.branch)
        }
    }
}
