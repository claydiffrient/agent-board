import Foundation

/// The prompt a round's follow-up checker is spawned with (SPEC §13.1). A rostered agent chosen for the
/// follow-up check role replaces the opening identity line and nothing after it; its grading lens lives
/// in that agent's own prompt and plugins.
public enum FollowupCheckPrompt {
    public static func compose(
        watch: PRWatch, round: PRRound, headOid: String, workingDirectory: String, agent: AgentIdentity? = nil,
        fenceId: String = InjectedNote.newFenceId()
    ) -> String {
        [
            agent.map(OpeningPrompt.renderIdentity) ?? identity,
            pullRequest(watch: watch, round: round, headOid: headOid, workingDirectory: workingDirectory),
            TriagePrompt.currentText(watch: watch, fenceId: fenceId),
            TriagePrompt.dataNotInstructions,
            grades,
            howToWork,
        ].joined(separator: "\n\n")
    }

    /// Rebuilt from the round, so a compacted checker gets back what it was spawned with. Nil when the
    /// session is not bound to a follow-up check.
    public static func postCompactionBrief(db: AppDatabase, session: AgentSession) throws -> String? {
        let store = PRWatchStore(db)
        guard let taskId = session.taskId, let round = try store.round(followupTaskId: taskId),
              let headOid = round.checkedHeadOid, let watch = try store.get(round.watchId)
        else { return nil }
        let agent = try session.rosterAgentId.flatMap {
            try RosterStore(db).resolved($0, forProject: session.projectId)
        }?.identity
        let prompt = compose(watch: watch, round: round, headOid: headOid, workingDirectory: session.cwd, agent: agent)
        return "Your conversation was just compacted, so your follow-up check may have been summarized away. "
            + "You still only read and record grades, and the check is not finished until every item has one. "
            + "It is reproduced in full.\n\n" + prompt
    }

    static let identity = """
    # You are checking a round of fixes
    You grade whether each review item a fixer worked on is now addressed. You read the code and record \
    grades; file-write tools, `gh` and git writes are denied to you, and you edit no file any other way.
    """

    static func pullRequest(watch: PRWatch, round: PRRound, headOid: String, workingDirectory: String) -> String {
        """
        ## The round
        \(watch.repoOwner)/\(watch.repoName)#\(watch.number), titled as below
        \(watch.url)
        - Round \(round.number) started from the pull request's head at `\(round.baseHeadOid)`, and its fixer \
        committed on top of it up to `\(headOid)`.
        - You are in `\(workingDirectory)`, a detached checkout of `\(headOid)`. The round's fixes are \
        `git diff \(round.baseHeadOid)..\(headOid)`, and `git log \(round.baseHeadOid)..\(headOid)` lists them.
        """
    }

    static let grades = """
    ## Grades
    Give each item exactly one, with the evidence for it: the file and line, or the command, that shows it.
    - `fixed`: the change the item asked for is made, and nothing it asked for is missing.
    - `partly`: some of it is made, and the evidence says what is still missing.
    - `not_fixed`: the round does not address it.
    - `moot`: it no longer applies, because the code it was about is gone or changed so the point no \
    longer holds. Say what made it moot.
    - `needs_author`: no commit can satisfy it, because only the pull request's author can do it on GitHub, \
    such as editing the description or title, changing labels or reviewers, or replying elsewhere. Say what \
    the author has to do; it goes to them as a decision.
    An item asking for a change to the title or description is graded against their current text above, \
    not the diff: `fixed` when that text shows the change, quoting the passage as evidence, and \
    `needs_author` when it does not or the passage cannot be seen.
    Anything but `fixed`, `moot` or `needs_author` sends the round back to its fixer with your evidence as the \
    finding, so write it for the fixer to act on.
    """

    static let howToWork = """
    ## How to work
    1. Call `get_followup_items` for the round and the items it fixed, each with triage's approach.
    2. Read the round's diff and the code around each item. File edits, git commands that change anything, \
    and `gh` are denied to this session.
    3. Call `set_followup_grades` with a grade and evidence for each item. You may call it more than once; a \
    later grade for the same item replaces the earlier one. The check ends when every item has one, and the \
    answer says which items still lack one.
    `log_progress` puts anything else on the record. Do not end your turn to wait for anything: a turn that \
    ends before every item has a grade leaves the round unchecked.
    """
}
