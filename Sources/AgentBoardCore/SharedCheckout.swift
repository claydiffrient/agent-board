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
    public static let branchPrefix = "agentboard/shared"

    public var branch: String
    public var memberSessionIds: [String]
    /// From `ProjectSettings.sharedCheckoutMaxAgents`; per-file locks are what make anything above 1 safe.
    public var maxMembers: Int

    public init(branch: String, memberSessionIds: [String], maxMembers: Int = ProjectSettings().sharedCheckoutMaxAgents) {
        self.branch = branch
        self.memberSessionIds = memberSessionIds
        self.maxMembers = maxMembers
    }

    public var isFull: Bool { memberSessionIds.count >= maxMembers }

    /// A shared branch is cut once from one base, so its name carries that base's identity: every
    /// member is in the same epic, or in no epic at all. A task whose base differs asks for a
    /// different branch name here and therefore never joins.
    public static func branch(epicId: String?) -> String {
        guard let epicId else { return branchPrefix }
        return "\(branchPrefix)-epic-\(epicId)"
    }

    /// The group holding `projectId`'s checkout, or nil when no worker is in it.
    public static func current(db: AppDatabase, projectId: String, maxMembers: Int? = nil) throws -> SharedCheckoutGroup? {
        let members = try SessionStore(db).active(projectId: projectId)
            .filter { $0.role == .worker && $0.worktreePath == nil }
        guard let branch = members.first?.branch else { return nil }
        let limit = try maxMembers
            ?? ProjectStore(db).get(projectId)?.settings.sharedCheckoutMaxAgents
            ?? ProjectSettings().sharedCheckoutMaxAgents
        return SharedCheckoutGroup(branch: branch, memberSessionIds: members.map(\.sessionId), maxMembers: limit)
    }

    /// Whether `session` is a worker running in `project`'s own checkout rather than a worktree.
    ///
    /// Both halves are needed. No worktree path alone is how a group member is recognised when the
    /// group is rebuilt from the session rows, but a row can carry no worktree path for other
    /// reasons — a stub, a session recorded before the row was finished — and a control that reads
    /// that as "shared" would fire on a worker standing somewhere else entirely.
    public static func isMember(_ session: AgentSession, of project: Project) -> Bool {
        guard session.role == .worker, session.worktreePath == nil else { return false }
        return resolved(session.cwd) == resolved(project.repoPath)
    }

    private static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
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

/// One task that shares a branch with others, as acceptance sees it.
public struct SharedBranchMember: Sendable, Equatable {
    public var taskId: String
    public var isAccepted: Bool

    public init(taskId: String, isAccepted: Bool) {
        self.taskId = taskId
        self.isAccepted = isAccepted
    }
}

/// When a shared branch may be merged into its epic branch and reaped.
///
/// A shared branch merges once, as a whole, when every member is accepted: its members' commits
/// are interleaved on one ref, so there is no range that is one task's work and no way to leave a
/// sibling's out. A member that was rejected, failed, or is being redone therefore holds the whole
/// branch until it is accepted on that same branch — Agent Board does not unpick commits.
public enum SharedBranchAcceptance {
    public static func isReadyToMerge(_ members: [SharedBranchMember]) -> Bool {
        !members.isEmpty && members.allSatisfy(\.isAccepted)
    }

    public static func waitingOn(_ members: [SharedBranchMember]) -> [String] {
        members.filter { !$0.isAccepted }.map(\.taskId)
    }
}

/// Where a worker is actually standing, read back from its own session row.
///
/// A resource read carries no arguments, so a briefing has only the token's identity to go on.
/// Deriving the branch from the task id yields `agentboard/<task-id>`, which is the branch a
/// worktree worker is on and is not the branch a shared-checkout worker is on: a shared branch is
/// cut once per base and its name carries that base rather than any one task. The session row
/// records the branch and the worktree path already — the same pair `SharedCheckoutGroup` rebuilds
/// its membership from.
public struct WorkerStanding: Sendable, Equatable {
    public var branch: String
    public var placement: WorkerPlacement
    public var workingDirectory: String?

    public init(branch: String, placement: WorkerPlacement, workingDirectory: String? = nil) {
        self.branch = branch
        self.placement = placement
        self.workingDirectory = workingDirectory
    }

    /// A nil `session` is the pre-spawn case: nothing is recorded yet, so the task-id branch is the
    /// only answer available and the placement is the default.
    public static func recorded(session: AgentSession?, project: Project, taskId: String) -> WorkerStanding {
        guard let session else {
            return WorkerStanding(branch: TaskStore.branchName(for: taskId), placement: .worktree)
        }
        guard let branch = session.branch else {
            return WorkerStanding(
                branch: TaskStore.branchName(for: taskId), placement: .worktree, workingDirectory: session.cwd
            )
        }
        let placement: WorkerPlacement = SharedCheckoutGroup.isMember(session, of: project)
            ? .shared(branch: branch)
            : .worktree
        return WorkerStanding(branch: branch, placement: placement, workingDirectory: session.cwd)
    }
}
