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

    public init(
        taskId: String,
        title: String,
        branch: String,
        disposition: Disposition,
        commit: String? = nil
    ) {
        self.taskId = taskId
        self.title = title
        self.branch = branch
        self.disposition = disposition
        self.commit = commit
    }

    var shortCommit: String? { commit.map { String($0.prefix(8)) } }
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
            let branch = branchName(taskId: task.id)
            let fact = facts[task.id] ?? TaskBranchFacts()
            guard !fact.branchExists else {
                return IntegrationBranch(
                    taskId: task.id, title: task.title, branch: branch,
                    disposition: fact.mergedIntoEpic ? .alreadyMerged : .merge
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
                taskId: task.id, title: task.title, branch: branch, disposition: disposition, commit: commit
            )
        }
    }

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
            merge.append(toMerge.enumerated().map { "\($0.offset + 1). `\($0.element.branch)` — \($0.element.title)" }
                .joined(separator: "\n"))
        }
        sections.append(merge.joined(separator: "\n\n"))

        if !alreadyMerged.isEmpty {
            sections.append("""
            ## Already merged into `\(epic.branch)` — skip these
            \(alreadyMerged.map { "- `\($0.branch)` — \($0.title)" }.joined(separator: "\n"))
            """)
        }
        if !landed.isEmpty {
            sections.append("""
            ## Already on `\(epic.branch)` — their branches were deleted, nothing to do
            \(landed.map { "- `\($0.branch)` — \($0.title)\($0.shortCommit.map { " (landed as \($0))" } ?? "")" }
                .joined(separator: "\n"))

            Each of these merged into `\(epic.branch)` and its branch was then deleted, which is the \
            normal end of an accepted task. Their work is in the history you are standing on. Do not \
            try to merge them, do not report them as missing, and do not rebuild any of it.
            """)
        }
        if !missing.isEmpty {
            sections.append("""
            ## No branch exists for these tasks
            \(missing.map { "- `\($0.branch)` — \($0.title)" }.joined(separator: "\n"))

            Nothing was ever committed on them. Do not try to merge them; name them in your report.
            """)
        }
        if !unknown.isEmpty {
            sections.append("""
            ## Branch gone, outcome unknown — check before you report on these
            \(unknown.map { "- `\($0.branch)` — \($0.title)\($0.shortCommit.map { " (last recorded tip \($0))" } ?? "")" }
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
