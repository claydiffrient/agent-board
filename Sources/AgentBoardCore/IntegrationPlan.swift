import Foundation

/// One task branch the integrator is told about, and what it should do with it.
public struct IntegrationBranch: Sendable, Equatable {
    public enum Disposition: String, Sendable, Equatable {
        case merge
        case alreadyMerged
        /// The branch is gone because its work was merged; nothing is left to do.
        case landed
        /// Nothing was ever committed for this task.
        case missing
        /// The branch is gone and where its work went cannot be established.
        case unknown
    }

    public var taskId: String
    public var title: String
    public var branch: String
    public var disposition: Disposition
    /// The recorded tip of a branch git no longer has, when one was recorded.
    public var commit: String?
    /// `branch` is shared with this task's siblings rather than its own. Several entries then name
    /// one branch, and merging it brings all of their work in at once.
    public var isShared: Bool

    public init(
        taskId: String,
        title: String,
        branch: String,
        disposition: Disposition,
        commit: String? = nil,
        isShared: Bool = false
    ) {
        self.taskId = taskId
        self.title = title
        self.branch = branch
        self.disposition = disposition
        self.commit = commit
        self.isShared = isShared
    }

    var shortCommit: String? { commit.map { String($0.prefix(8)) } }

    /// One line in a section that is not the merge list, where the branch is named per task.
    var listing: String {
        isShared ? "`\(branch)` (shared) — \(title)" : "`\(branch)` — \(title)"
    }
}

/// The integrator's opening prompt (§5.2 step 3). Pure, so the branch ordering and the skip list
/// are testable without a repository.
public enum IntegrationPlan {
    public static func branchName(taskId: String) -> String { "agentboard/\(taskId)" }

    public static func taskTitle(epic: Epic) -> String { "Integrate epic \(epic.title)" }

    /// Dependency order: a task is listed after every task it depends on. Dependencies outside
    /// `tasks` are ignored, and a cycle falls back to board order rather than dropping tasks.
    public static func order(_ tasks: [BoardTask], deps: [String: [String]]) -> [BoardTask] {
        let known = Set(tasks.map(\.id))
        var remaining = tasks
        var placed: Set<String> = []
        var ordered: [BoardTask] = []
        while !remaining.isEmpty {
            let ready = remaining.firstIndex { task in
                (deps[task.id] ?? []).allSatisfy { !known.contains($0) || placed.contains($0) }
            }
            let next = remaining.remove(at: ready ?? remaining.startIndex)
            placed.insert(next.id)
            ordered.append(next)
        }
        return ordered
    }

    /// `facts` is keyed by task id. A branch that no longer exists is read from the ledger rather
    /// than from its own absence: it was just as likely deleted for having been merged.
    public static func classify(_ tasks: [BoardTask], facts: [String: TaskBranchFacts]) -> [IntegrationBranch] {
        tasks.map { task in
            let fact = facts[task.id] ?? TaskBranchFacts()
            let isShared = fact.sharedBranch != nil
            let branch = fact.sharedBranch ?? branchName(taskId: task.id)
            guard !fact.branchExists else {
                // A shared branch that exists still has to be merged for its siblings, but a member
                // that committed nothing on it contributed nothing to that merge.
                let contributed = !isShared || (fact.ownCommits ?? 1) > 0
                let disposition: IntegrationBranch.Disposition = !contributed
                    ? .missing
                    : (fact.mergedIntoEpic ? .alreadyMerged : .merge)
                return IntegrationBranch(
                    taskId: task.id, title: task.title, branch: branch,
                    disposition: disposition, isShared: isShared
                )
            }
            let disposition: IntegrationBranch.Disposition
            var commit: String?
            switch TaskBranchEvidence.read(fact) {
            case .landed(let tip):
                disposition = .landed
                commit = tip
            case .nothingCommitted:
                disposition = .missing
            case .offEpicBranch(let tip):
                disposition = .unknown
                commit = tip
            case .unestablished:
                disposition = .unknown
            }
            return IntegrationBranch(
                taskId: task.id, title: task.title, branch: branch, disposition: disposition,
                commit: commit, isShared: isShared
            )
        }
    }

    /// The merge list, with the tasks that share one branch collapsed onto one numbered line: the
    /// integrator merges a branch, and a shared branch listed twice would be merged twice.
    static func mergeList(_ branches: [IntegrationBranch]) -> [String] {
        var order: [String] = []
        var byBranch: [String: [IntegrationBranch]] = [:]
        for entry in branches {
            if byBranch[entry.branch] == nil { order.append(entry.branch) }
            byBranch[entry.branch, default: []].append(entry)
        }
        return order.enumerated().map { index, name in
            let group = byBranch[name] ?? []
            guard group.count > 1 else { return "\(index + 1). `\(name)` — \(group.first?.title ?? name)" }
            return "\(index + 1). `\(name)` — one branch shared by \(group.count) tasks: "
                + group.map(\.title).joined(separator: "; ")
        }
    }

    /// Said once, in the merge list, when any branch in it is shared. The three claims a branch can
    /// carry — merge, landed, never committed — are unchanged; what a shared branch adds is that
    /// one of them covers several tasks at once.
    static let sharedBranchNote = """
        A branch listed above as shared carries several tasks' commits interleaved on one ref: \
        those tasks ran co-resident in the project's own checkout rather than in a worktree of \
        their own. Merging it brings all of their work in at once, which is the only way it can be \
        merged — do not try to separate one task's commits out. Each commit names its task in an \
        `Agent-Board-Task:` trailer if you need to see who wrote what: \
        `git log --format='%h %s %(trailers:key=Agent-Board-Task,valueonly)' <branch>`.
        """

    public static func compose(
        epic: Epic,
        baseBranch: String,
        branches: [IntegrationBranch],
        verification: VerificationCommands
    ) -> String {
        let toMerge = branches.filter { $0.disposition == .merge }
        let alreadyMerged = branches.filter { $0.disposition == .alreadyMerged }
        let landed = branches.filter { $0.disposition == .landed }
        let missing = branches.filter { $0.disposition == .missing }
        let unknown = branches.filter { $0.disposition == .unknown }

        var sections: [String] = []
        sections.append("# Task: \(taskTitle(epic: epic))")
        sections.append(
            "Merge this epic's task branches into the epic branch `\(epic.branch)` and leave the build green. "
                + "You are the integrator: no other agent is working on these branches."
        )
        sections.append("## Epic goal\n\(epic.goal?.isEmpty == false ? epic.goal! : "(No goal was recorded for this epic.)")")

        var merge = ["## Branches to merge, in dependency order"]
        if toMerge.isEmpty {
            merge.append("Nothing is left to merge. Verify the state of `\(epic.branch)` and report what you found.")
        } else {
            merge.append("Merge these into `\(epic.branch)` in exactly this order — each is listed after the branches it depends on.")
            merge.append(mergeList(toMerge).joined(separator: "\n"))
            if toMerge.contains(where: \.isShared) { merge.append(sharedBranchNote) }
        }
        sections.append(merge.joined(separator: "\n\n"))

        if !alreadyMerged.isEmpty {
            sections.append("""
            ## Already merged into `\(epic.branch)` — skip these
            \(alreadyMerged.map { "- " + $0.listing }.joined(separator: "\n"))
            """)
        }
        if !landed.isEmpty {
            sections.append("""
            ## Already on `\(epic.branch)` — their branches were deleted, nothing to do
            \(landed.map { "- " + $0.listing + ($0.shortCommit.map { " (landed as \($0))" } ?? "") }
                .joined(separator: "\n"))

            Each of these merged into `\(epic.branch)` and its branch was then deleted, which is the \
            normal end of an accepted task. A branch marked shared was one branch for several tasks \
            and was deleted once, after the last of them was accepted. Their work is in the history \
            you are standing on. Do not try to merge them, do not report them as missing, and do not \
            rebuild any of it.
            """)
        }
        if !missing.isEmpty {
            sections.append("""
            ## No branch exists for these tasks
            \(missing.map { "- " + $0.listing }.joined(separator: "\n"))

            Nothing was ever committed on them. A branch marked shared may still be listed above \
            for its other tasks — this task simply put no commit on it. Do not try to merge \
            anything on their behalf; name them in your report.
            """)
        }
        if !unknown.isEmpty {
            sections.append("""
            ## Branch gone, outcome unknown — check before you report on these
            \(unknown.map { "- " + $0.listing + ($0.shortCommit.map { " (last recorded tip \($0))" } ?? "") }
                .joined(separator: "\n"))

            Agent Board cannot tell whether their work reached `\(epic.branch)`. A missing branch is \
            not evidence either way — task branches are deleted once they merge. Establish it \
            yourself before writing anything down: `git log --oneline \(epic.branch)`, and where a \
            tip is named above, `git merge-base --is-ancestor <tip> \(epic.branch)`. Report what you \
            found. Do not rebuild work you have not confirmed is absent.
            """)
        }

        sections.append("""
        ## How to work
        - You are in a dedicated git worktree checked out on `\(epic.branch)`. Work only in this directory.
        - Merge the branches under **Branches to merge**, in that order, one at a time: `git merge --no-ff <branch>`. Nothing listed in any other section is yours to merge.
        - Resolve every conflict yourself. Read both sides before choosing; do not drop one side's work to make the merge go through.
        - After the merges, \(verification.integratorInstruction)
        - The `agent-board` MCP server holds this assignment. Use `log_progress` at meaningful milestones, not after every merge.
        - If you are stuck on something that needs a human decision, call `report_blocked(reason)` and stop.
        """)
        sections.append("""
        ## When you are done
        1. Commit on `\(epic.branch)`. Write the message in imperative mood, with no conventional-commit prefix.
        2. Do not push. Do not open a PR. Both are denied at the tool layer; do not spend a turn discovering that. \
        The pull request from `\(epic.branch)` into `\(baseBranch)` is opened outside this session, by a human or \
        by the orchestrator through an approval the human grants.
        3. Call `report_complete(summary, files_changed, tests_run, caveats)`. Say which branches you merged, which you \
        skipped and why, and \(verification.reportInstruction). That ends your task; do not start \
        further work afterwards.
        """)
        return sections.joined(separator: "\n\n")
    }
}
