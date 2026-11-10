import Foundation

/// What git says a dead worker left on its task branch. Whoever can run git gathers it — `Board`
/// shells out to nothing — and `Board` reads it so a session that ended without reporting cannot
/// send committed work back to `ready` as though the branch were empty.
public struct BranchSalvage: Sendable, Equatable {
    public var branch: String
    /// Commits the branch carries that the commit it was cut from does not.
    public var commitsAheadOfBase: Int
    /// Edits the worker never committed. Cheap to read, and only a human can do anything with them.
    public var uncommittedChanges: Bool

    public init(branch: String, commitsAheadOfBase: Int, uncommittedChanges: Bool = false) {
        self.branch = branch
        self.commitsAheadOfBase = max(0, commitsAheadOfBase)
        self.uncommittedChanges = uncommittedChanges
    }

    public var hasCommittedWork: Bool { commitsAheadOfBase > 0 }

    /// What accepting the task must say first (SPEC §5, `done`): nil unless the branch holds no commits and the worktree is dirty.
    public var acceptWarning: String? {
        guard !hasCommittedWork, uncommittedChanges else { return nil }
        return "Branch \(branch) contains no committed work, and the task's worktree has uncommitted changes. "
            + "Accepting moves the task to Done without that work: nothing lands, and the worktree is kept with the changes in it."
    }

    /// What a failure report says about the branch. It never claims the work is finished or that it
    /// builds: no worker reported on it and Agent Board compiles nothing.
    public var sentence: String {
        guard hasCommittedWork else {
            return uncommittedChanges
                ? "Branch \(branch) carries no commits its base does not, but the worktree has uncommitted edits."
                : "Branch \(branch) carries no commits its base does not."
        }
        var line = "Branch \(branch) carries \(commitsAheadOfBase) commit\(commitsAheadOfBase == 1 ? "" : "s") its base does not."
        if uncommittedChanges { line += " The worktree also has uncommitted edits." }
        line += " No worker reported on that work and Agent Board has not built it, so it is unverified, not finished."
        return line
    }
}
