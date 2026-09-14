import Foundation

/// One task branch the integrator is told about, and what it should do with it.
public struct IntegrationBranch: Sendable, Equatable {
    public enum Disposition: String, Sendable, Equatable {
        case merge
        case alreadyMerged
        case missing
    }

    public var taskId: String
    public var title: String
    public var branch: String
    public var disposition: Disposition

    public init(taskId: String, title: String, branch: String, disposition: Disposition) {
        self.taskId = taskId
        self.title = title
        self.branch = branch
        self.disposition = disposition
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

    /// `merged` and `exists` come from `WorktreeManager.mergeStatus` and `branchExists`; a branch
    /// git never saw is called out rather than handed to the integrator as something to merge.
    public static func classify(
        _ tasks: [BoardTask],
        merged: [String: Bool],
        exists: Set<String>
    ) -> [IntegrationBranch] {
        tasks.map { task in
            let branch = branchName(taskId: task.id)
            let disposition: IntegrationBranch.Disposition
            if merged[branch] == true {
                disposition = .alreadyMerged
            } else if exists.contains(branch) {
                disposition = .merge
            } else {
                disposition = .missing
            }
            return IntegrationBranch(taskId: task.id, title: task.title, branch: branch, disposition: disposition)
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
        let missing = branches.filter { $0.disposition == .missing }

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
        if !missing.isEmpty {
            sections.append("""
            ## No branch exists for these tasks
            \(missing.map { "- `\($0.branch)` — \($0.title)" }.joined(separator: "\n"))

            Nothing was ever committed on them. Do not try to merge them; name them in your report.
            """)
        }

        sections.append("""
        ## How to work
        - You are in a dedicated git worktree checked out on `\(epic.branch)`. Work only in this directory.
        - Merge each branch listed above in order, one at a time: `git merge --no-ff <branch>`.
        - Resolve every conflict yourself. Read both sides before choosing; do not drop one side's work to make the merge go through.
        - After the merges, \(verification.integratorInstruction)
        - The `agent-board` MCP server holds this assignment. Use `log_progress` at meaningful milestones, not after every merge.
        - If you are stuck on something that needs a human decision, call `report_blocked(reason)` and stop.
        """)
        sections.append("""
        ## When you are done
        1. Commit on `\(epic.branch)`. Write the message in imperative mood, with no conventional-commit prefix.
        2. Do not push. Do not open a PR. Both are denied at the tool layer; do not spend a turn discovering that. \
        A human opens the pull request from `\(epic.branch)` into `\(baseBranch)`.
        3. Call `report_complete(summary, files_changed, tests_run, caveats)`. Say which branches you merged, which you \
        skipped and why, and \(verification.reportInstruction). That ends your task; do not start \
        further work afterwards.
        """)
        return sections.joined(separator: "\n\n")
    }
}
