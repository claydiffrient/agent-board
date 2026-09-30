import Foundation

/// What merging the epic branch into a task's worktree on resume did (SPEC §5, "Resumed").
public struct ResumeMerge: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case upToDate
        /// `commits` are subjects along the epic branch's first parent; `files` are the paths the
        /// merge changed in the worktree.
        case merged(commits: [String], files: [String])
        case conflicted(files: [String])
        /// An earlier resume's merge is still unresolved, so nothing new was attempted.
        case stillConflicted(files: [String])
        case failed(String)
    }

    public var epicBranch: String
    public var outcome: Outcome
    /// The commit made of the previous run's uncommitted changes before merging.
    public var savedWork: String?

    public init(epicBranch: String, outcome: Outcome, savedWork: String? = nil) {
        self.epicBranch = epicBranch
        self.outcome = outcome
        self.savedWork = savedWork
    }

    public static let savedWorkSubject = "Save uncommitted work left by an interrupted run"
}

extension WorktreeManager {
    /// Never throws: whatever happens, the worker is resumed and told, and a commit already made
    /// of its uncommitted work must still be reported.
    public func mergeEpicBranch(_ epicBranch: String, intoWorktree worktree: URL, message: String) -> ResumeMerge {
        var savedWork: String?
        func result(_ outcome: ResumeMerge.Outcome) -> ResumeMerge {
            ResumeMerge(epicBranch: epicBranch, outcome: outcome, savedWork: savedWork)
        }
        do {
            let epicRef = "refs/heads/\(epicBranch)"
            if try gitRaw(["rev-parse", "--quiet", "--verify", "MERGE_HEAD"], cwd: worktree).status == 0 {
                return result(.stillConflicted(files: try unmergedFiles(in: worktree)))
            }
            guard try commitExists(epicRef) else {
                return result(.failed("the epic branch `\(epicBranch)` does not exist"))
            }
            switch try gitRaw(["merge-base", "--is-ancestor", epicRef, "HEAD"], cwd: worktree).status {
            case 0: return result(.upToDate)
            case 1: break
            case let status: return result(.failed("git merge-base --is-ancestor exited \(status)"))
            }
            let config = try mergeConfig()
            if try hasUncommittedChanges(worktree: worktree) {
                try gitChecked(["add", "-A"], cwd: worktree)
                try gitChecked(
                    config + ["commit", "--quiet", "--no-verify", "-m", ResumeMerge.savedWorkSubject], cwd: worktree
                )
                savedWork = try gitChecked(["rev-parse", "--short", "HEAD"], cwd: worktree)
                    .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let before = try headCommit(worktree: worktree)
            let merge = try gitRaw(
                config + ["merge", "--no-verify", "--no-edit", "-m", message, epicRef], cwd: worktree
            )
            if merge.status != 0 {
                if try gitRaw(["rev-parse", "--quiet", "--verify", "MERGE_HEAD"], cwd: worktree).status == 0 {
                    return result(.conflicted(files: try unmergedFiles(in: worktree)))
                }
                let output = [merge.stderr, merge.stdout]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty } ?? "git merge exited \(merge.status)"
                return result(.failed(output))
            }
            let commits = try lines(gitChecked(
                ["log", "--first-parent", "--format=%s", "\(before)..\(epicRef)"], cwd: worktree
            ).stdout)
            let files = try lines(gitChecked(["diff", "--name-only", before, "HEAD"], cwd: worktree).stdout)
            return result(.merged(commits: commits, files: files))
        } catch {
            return result(.failed(String(describing: error)))
        }
    }

    private func unmergedFiles(in worktree: URL) throws -> [String] {
        try lines(gitChecked(["diff", "--name-only", "--diff-filter=U"], cwd: worktree).stdout)
    }

    private func lines(_ output: String) -> [String] {
        output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }
}
