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
    /// Every commit on `branch` since `base`, newest first, paired with the task the ledger says
    /// made it.
    ///
    /// A commit with no ledger row reads as `taskId: nil` — nobody's work. That covers a human's own
    /// commit, a commit made outside Agent Board's commit path, and a commit made before the ledger
    /// existed; `backfillFromTrailers` closes the last of those against a branch's old trailers.
    public func attributedCommits(on branch: String, since base: String) throws -> [AttributedCommit] {
        let shas = try shaRange(on: branch, since: base)
        guard !shas.isEmpty else { return [] }
        let ledger = try commitLedger?.taskIds(forShas: shas) ?? [:]
        return shas.map { AttributedCommit(sha: $0, taskId: ledger[$0]) }
    }

    /// Records the task id carried by the `Agent-Board-Task` trailer of any commit on `branch` that
    /// predates the ledger, and returns how many rows it added.
    ///
    /// The trailer is no longer written — it published a task's UUID into whatever repository the
    /// pull request landed in. This reads history back once so a branch that already carries it
    /// stays attributable; it never writes a trailer, and no commit is rewritten. `%(trailers:key=)`
    /// parses only genuine trailers in the message's last paragraph, so a body that quotes another
    /// task's trailer cannot be mistaken for that task's work.
    @discardableResult
    public func backfillFromTrailers(on branch: String, since base: String) throws -> Int {
        guard let ledger = commitLedger else { return 0 }
        let shas = try shaRange(on: branch, since: base)
        guard !shas.isEmpty else { return 0 }
        let known = try ledger.taskIds(forShas: shas)
        guard known.count < shas.count else { return 0 }
        let format = "--format=%x01%H%x02%(trailers:key=Agent-Board-Task,valueonly)"
        let output = try gitChecked(["log", format, "--no-merges", "\(base)..\(branch)"], cwd: repoPath).stdout
        let rows: [(taskId: String, sha: String)] = output.split(separator: "\u{01}").compactMap { record in
            let halves = record.split(separator: "\u{02}", maxSplits: 1, omittingEmptySubsequences: false)
            let sha = halves[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard sha.count == 40, known[sha] == nil, halves.count > 1 else { return nil }
            let taskId = halves[1].split(separator: "\n").first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return taskId.isEmpty ? nil : (taskId: taskId, sha: sha)
        }
        try ledger.record(rows)
        return rows.count
    }

    /// The shas on `branch` that `base` does not have, newest first. Empty when either ref is gone.
    private func shaRange(on branch: String, since base: String) throws -> [String] {
        guard try commitExists(base), try commitExists(branch) else { return [] }
        return try gitChecked(["log", "--format=%H", "--no-merges", "\(base)..\(branch)"], cwd: repoPath)
            .stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count == 40 }
    }

    public func commits(taskId: String, on branch: String, since base: String) throws -> [String] {
        try attributedCommits(on: branch, since: base).filter { $0.taskId == taskId }.map(\.sha)
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
