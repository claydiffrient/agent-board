import AgentBoardCore
import Foundation

/// One commit on a shared branch and the task that made it.
public struct AttributedCommit: Sendable, Equatable {
    public var sha: String
    public var taskId: String?

    public init(sha: String, taskId: String?) {
        self.sha = sha
        self.taskId = taskId
    }
}

extension WorktreeManager {
    /// Every commit on `branch` since `base`, newest first, paired with the task its trailer names.
    ///
    /// Read through git's own `%(trailers)` atom rather than `--grep`, because that atom parses only
    /// genuine trailers in the message's last paragraph: a commit body that quotes another task's
    /// trailer cannot be mistaken for that task's work.
    public func attributedCommits(on branch: String, since base: String) throws -> [AttributedCommit] {
        guard try commitExists(base), try commitExists(branch) else { return [] }
        let format = "--format=%x01%H%x02%(trailers:key=\(CommitAttribution.trailerKey),valueonly)"
        let output = try gitChecked(["log", format, "--no-merges", "\(base)..\(branch)"], cwd: repoPath).stdout
        return output.split(separator: "\u{01}").compactMap { record in
            let halves = record.split(separator: "\u{02}", maxSplits: 1, omittingEmptySubsequences: false)
            let sha = halves[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard sha.count == 40 else { return nil }
            let value = halves.count > 1
                ? halves[1].split(separator: "\n").first.map(String.init) ?? ""
                : ""
            return AttributedCommit(sha: sha, taskId: CommitAttribution.taskId(trailerValue: value))
        }
    }

    public func commits(taskId: String, on branch: String, since base: String) throws -> [String] {
        try attributedCommits(on: branch, since: base).filter { $0.taskId == taskId }.map(\.sha)
    }

    /// Where `branch` was cut from `other`, which is what "since the base" means for a shared branch:
    /// the epic branch it came from has usually moved on since.
    public func mergeBase(_ branch: String, _ other: String) throws -> String? {
        let result = try gitRaw(["merge-base", branch, other], cwd: repoPath)
        guard result.status == 0 else { return nil }
        let commit = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return commit.isEmpty ? nil : commit
    }

    /// Writes the per-task ledger for every member of a shared branch, before the branch is deleted.
    ///
    /// A shared branch's tip belongs to no single task, so recording it as one member's would be a
    /// claim the branch cannot support. Each member gets its own newest attributed commit instead,
    /// and a member that committed nothing gets the base, which is how the ledger already says
    /// "carried nothing its base did not".
    @discardableResult
    public func recordSharedLedger(branch: String, base: String, taskIds: [String]) throws -> [String: String] {
        guard let baseCommit = try refCommit(base) else { return [:] }
        var tips: [String: String] = [:]
        for commit in try attributedCommits(on: branch, since: base) {
            guard let taskId = commit.taskId, tips[taskId] == nil else { continue }
            tips[taskId] = commit.sha
        }
        for taskId in taskIds {
            try? setRef(TaskBranchLedger.baseRef(taskId: taskId), to: baseCommit)
            try? setRef(TaskBranchLedger.tipRef(taskId: taskId), to: tips[taskId] ?? baseCommit)
        }
        return tips
    }

    /// Moves the project's own checkout off a shared branch so the branch can be deleted. Throws
    /// rather than discarding anything when the checkout is dirty — the branch then survives.
    public func releaseSharedBranch(_ branch: String, to fallback: String) throws {
        guard try currentBranch(at: repoPath) == branch else { return }
        if try hasUncommittedChanges(worktree: repoPath) {
            throw AgentRuntimeError(
                "\(repoPath.path) has uncommitted changes, so it cannot be moved off \(branch)"
            )
        }
        try gitChecked(["checkout", fallback], cwd: repoPath)
    }

    /// The per-file totals across `commits`, summed. A file touched by two of a task's commits is
    /// one changed file with both commits' lines, which is what "what did this task change" means.
    public func fileTotals(commits: [String]) throws -> [FileDiffTotal] {
        guard !commits.isEmpty else { return [] }
        let output = try gitChecked(["show", "--numstat", "--format=", "--no-renames"] + commits, cwd: repoPath).stdout
        var totals: [String: FileDiffTotal] = [:]
        var order: [String] = []
        for rawLine in output.split(separator: "\n") {
            let fields = rawLine.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, !fields[2].isEmpty else { continue }
            let path = String(fields[2])
            if totals[path] == nil {
                totals[path] = FileDiffTotal(path: path)
                order.append(path)
            }
            if let added = Int(fields[0]), let deleted = Int(fields[1]) {
                totals[path]?.insertions += added
                totals[path]?.deletions += deleted
            } else {
                totals[path]?.isBinary = true
            }
        }
        return order.compactMap { totals[$0] }
    }

    /// The diff of one task's commits on a shared branch, in the shape `diffstat(worktree:against:)`
    /// returns for a worktree task. Empty when the task has committed nothing — never its sibling's
    /// work.
    public func diffstat(taskId: String, on branch: String, since base: String) throws -> String {
        FileDiffTotal.renderStat(try fileTotals(commits: try commits(taskId: taskId, on: branch, since: base)))
    }

    public func diffSummary(taskId: String, on branch: String, since base: String) throws -> DiffSummary {
        FileDiffTotal.summary(try fileTotals(commits: try commits(taskId: taskId, on: branch, since: base)))
    }
}

public struct FileDiffTotal: Sendable, Equatable {
    public var path: String
    public var insertions: Int = 0
    public var deletions: Int = 0
    public var isBinary: Bool = false

    public init(path: String, insertions: Int = 0, deletions: Int = 0, isBinary: Bool = false) {
        self.path = path
        self.insertions = insertions
        self.deletions = deletions
        self.isBinary = isBinary
    }

    public static func summary(_ totals: [FileDiffTotal]) -> DiffSummary {
        DiffSummary(
            filesChanged: totals.count,
            insertions: totals.reduce(0) { $0 + $1.insertions },
            deletions: totals.reduce(0) { $0 + $1.deletions },
            binaryFiles: totals.filter(\.isBinary).count
        )
    }

    /// `git diff --stat`'s shape, rebuilt from the totals. Git's own `--stat` cannot produce this:
    /// it diffs two trees, and a task's commits on a shared branch are not a contiguous range.
    public static func renderStat(_ totals: [FileDiffTotal], barWidth: Int = 40) -> String {
        guard !totals.isEmpty else { return "" }
        let nameWidth = totals.map(\.path.count).max() ?? 0
        let peak = totals.map { $0.insertions + $0.deletions }.max() ?? 0
        var lines = totals.map { total -> String in
            let name = total.path.padding(toLength: max(nameWidth, total.path.count), withPad: " ", startingAt: 0)
            guard !total.isBinary else { return " \(name) | Bin" }
            let changed = total.insertions + total.deletions
            let scale = peak > barWidth ? Double(barWidth) / Double(peak) : 1
            let plus = Int((Double(total.insertions) * scale).rounded(.up))
            let minus = Int((Double(total.deletions) * scale).rounded(.up))
            return " \(name) | \(changed) \(String(repeating: "+", count: plus))\(String(repeating: "-", count: minus))"
        }
        var parts = ["\(totals.count) file\(totals.count == 1 ? "" : "s") changed"]
        let insertions = totals.reduce(0) { $0 + $1.insertions }
        let deletions = totals.reduce(0) { $0 + $1.deletions }
        if insertions > 0 { parts.append("\(insertions) insertion\(insertions == 1 ? "" : "s")(+)") }
        if deletions > 0 { parts.append("\(deletions) deletion\(deletions == 1 ? "" : "s")(-)") }
        lines.append(" " + parts.joined(separator: ", "))
        return lines.joined(separator: "\n") + "\n"
    }
}
