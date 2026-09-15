import Foundation

/// Where a task branch was cut and where it ended, written outside `refs/heads` so the record
/// outlives the branch. Agent Board deletes a task branch once its work is merged, so without this
/// a landed task and one that never committed look identical: both have no branch.
public enum TaskBranchLedger {
    public static func baseRef(taskId: String) -> String { "refs/agentboard/base/\(taskId)" }

    public static func tipRef(taskId: String) -> String { "refs/agentboard/reaped/\(taskId)" }

    /// `agentboard/<task-id>` → `<task-id>`. Epic branches are not task branches and have no ledger.
    public static func taskId(ofBranch branch: String) -> String? {
        guard branch.hasPrefix(TaskStore.branchPrefix), !branch.hasPrefix(EpicStore.branchPrefix) else { return nil }
        let id = String(branch.dropFirst(TaskStore.branchPrefix.count))
        return id.isEmpty ? nil : id
    }
}

/// What git and the board can say about one task's branch. Gathered by whoever can run git;
/// `TaskBranchEvidence.read` turns it into a claim that is either supported or withheld.
public struct TaskBranchFacts: Sendable, Equatable {
    public var branchExists: Bool
    public var mergedIntoEpic: Bool
    /// The commit `TaskBranchLedger.baseRef` holds — where the branch was cut.
    public var recordedBase: String?
    /// The commit `TaskBranchLedger.tipRef` holds — where the branch stood when it was deleted.
    public var recordedTip: String?
    /// Whether `recordedTip` is an ancestor of the epic branch. Nil when nothing was recorded.
    public var tipOnEpicBranch: Bool?
    /// Commits the branch carried that its base did not. Nil unless both refs were recorded.
    public var ownCommits: Int?
    /// False only when Agent Board is sure no worker was ever spawned on the task.
    public var everDispatched: Bool

    public init(
        branchExists: Bool = false,
        mergedIntoEpic: Bool = false,
        recordedBase: String? = nil,
        recordedTip: String? = nil,
        tipOnEpicBranch: Bool? = nil,
        ownCommits: Int? = nil,
        everDispatched: Bool = true
    ) {
        self.branchExists = branchExists
        self.mergedIntoEpic = mergedIntoEpic
        self.recordedBase = recordedBase
        self.recordedTip = recordedTip
        self.tipOnEpicBranch = tipOnEpicBranch
        self.ownCommits = ownCommits
        self.everDispatched = everDispatched
    }
}

/// What can honestly be said about a task whose branch git no longer has.
public enum TaskBranchEvidence: Sendable, Equatable {
    /// The branch was deleted after its work reached the epic branch.
    case landed(commit: String)
    /// No worker ever ran, or the branch was deleted carrying nothing its base did not already have.
    case nothingCommitted
    /// The branch carried work and the recorded tip is not on the epic branch.
    case offEpicBranch(commit: String)
    /// Neither claim is supported. The absence of a branch is not evidence for either one.
    case unestablished

    public static func read(_ facts: TaskBranchFacts) -> TaskBranchEvidence {
        guard let tip = facts.recordedTip else {
            return facts.everDispatched ? .unestablished : .nothingCommitted
        }
        guard let own = facts.ownCommits else { return .unestablished }
        guard own > 0 else { return .nothingCommitted }
        guard let onEpic = facts.tipOnEpicBranch else { return .unestablished }
        return onEpic ? .landed(commit: tip) : .offEpicBranch(commit: tip)
    }
}
