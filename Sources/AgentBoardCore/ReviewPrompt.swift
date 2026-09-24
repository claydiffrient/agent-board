import Foundation

/// The prompt a rostered reviewer is spawned with, and the `briefing://reviewer` resource it reads
/// back after a compaction (SPEC §5.1). A reviewer changes nothing: its deny list and the checkout
/// check on its verdict tools enforce what this text asks.
public enum ReviewPrompt {
    public static func compose(
        task: BoardTask,
        branch: String,
        base: String,
        verification: VerificationCommands = VerificationCommands(),
        workingDirectory: String? = nil,
        agent: AgentIdentity? = nil
    ) -> String {
        var sections = agent.map { [OpeningPrompt.renderIdentity($0)] } ?? []
        sections.append(
            "You are reviewing the task below. Another agent did the work; you decide whether it is done."
        )
        sections += OpeningPrompt.taskSections(task: task)
        sections.append(howToReview(
            branch: branch, base: base, verification: verification, workingDirectory: workingDirectory
        ))
        sections.append(verdict)
        sections.append(turnEnding)
        return sections.joined(separator: "\n\n")
    }

    /// Rebuilt from what the board recorded when the reviewer was spawned, so the resource cannot
    /// drift from the prompt. Nil when the session is not a reviewer's on a live task.
    public static func recorded(db: AppDatabase, session: AgentSession) throws -> String? {
        guard let taskId = session.taskId, let task = try TaskStore(db).get(taskId),
              let project = try ProjectStore(db).get(session.projectId)
        else { return nil }
        let base = try task.epicId.flatMap { try EpicStore(db).get($0) }?.branch ?? project.baseBranch
        let agent = try session.rosterAgentId.flatMap { try RosterStore(db).get($0) }?.identity
        return compose(
            task: task,
            branch: session.branch ?? TaskStore.branchName(for: taskId),
            base: base,
            verification: project.settings.verification,
            workingDirectory: session.cwd,
            agent: agent
        )
    }

    /// Handed back after a compaction. The whole prompt when it fits `OpeningPrompt.briefCharacterBudget`,
    /// otherwise a pointer to the resource that serves it.
    public static func postCompactionBrief(db: AppDatabase, session: AgentSession) throws -> String? {
        guard let prompt = try recorded(db: db, session: session) else { return nil }
        let lead = """
        Your conversation was just compacted, so your review assignment may have been summarized away. \
        You still change nothing, and the review is not finished until you call `accept_task` or `reopen_task`.
        """
        let whole = lead + " It is reproduced in full.\n\n" + prompt
        guard whole.count > OpeningPrompt.briefCharacterBudget else { return whole }
        return lead + " Read `\(BriefingResourceURI.reviewer)` with `resources/read` for the whole of it, "
            + "and call `get_my_task` for the task."
    }

    static func howToReview(
        branch: String, base: String, verification: VerificationCommands, workingDirectory: String?
    ) -> String {
        let here = workingDirectory.map { "`\($0)`" } ?? "this directory"
        var lines = [
            "## How to review",
            "- You are in \(here), on branch `\(branch)`, where the work was done. The work under review is "
                + "`git diff \(base)...HEAD`; `git log \(base)..HEAD` lists its commits.",
            "- You review and change nothing. Do not edit or create files, do not commit, and do not change "
                + "or move a branch. File edits and the git commands that change a branch are denied to this "
                + "session, and your verdict is refused if the branch HEAD or any tracked file has changed "
                + "since you started.",
            "- You may run a build and targeted tests to check a claim. Build output is fine.",
        ]
        if let build = verification.build { lines.append("- This project builds with `\(build)`.") }
        if let test = verification.test { lines.append("- This project tests with `\(test)`.") }
        lines.append(
            "- `get_my_task` returns the task, the worker's report and the progress recorded against it. "
                + "`log_progress` puts anything on the record that is not your verdict."
        )
        return lines.joined(separator: "\n")
    }

    static let verdict = """
    ## Your verdict
    Finish with exactly one of these:
    - `accept_task(verdict)` when the work meets its acceptance criteria. State what you checked, not only \
    that you approve.
    - `reopen_task(findings)` when anything must change. Do not fix it yourself. The next worker fixes it \
    from your findings, which reach its opening prompt verbatim, so make each one actionable on its own: \
    what is wrong, the file and line or the command that shows it, and what would make it acceptable.
    If either tool refuses your verdict, stop there. The task stays in Review for a person.
    """

    static let turnEnding = """
    ## How your turns end
    This session runs unattended. A message with no tool call in it ends your turn, and nothing resumes \
    it: the task sits in Review with nobody deciding it. Put status notes in the same message as your next \
    tool call. Your turn should end only after `accept_task` or `reopen_task`, or after one of them refused.
    """
}
