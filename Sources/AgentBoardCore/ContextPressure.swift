import Foundation

/// How full an orchestrator's context is, measured against the window Claude Code actually budgets
/// against (`effectiveWindow` in its own `--debug` log), not the model's raw context length.
public struct ContextPressure: Sendable, Equatable {
    public let usedTokens: Int
    public let limitTokens: Int

    public init(usedTokens: Int, limitTokens: Int) {
        self.usedTokens = usedTokens
        self.limitTokens = limitTokens
    }

    public var fraction: Double {
        guard limitTokens > 0 else { return 0 }
        return Double(usedTokens) / Double(limitTokens)
    }

    public var percent: Int {
        Int((fraction * 100).rounded())
    }

    public func exceeds(_ threshold: Double) -> Bool {
        guard limitTokens > 0 else { return false }
        return Double(usedTokens) >= threshold * Double(limitTokens)
    }
}

/// The app-authored half of orchestrator compaction (SPEC §9.2). Every string here is a fixed
/// constant: no agent text may enter the orchestrator's user-authority turn (D9).
public enum OrchestratorCompaction {
    /// Fraction of the effective window at which Agent Board compacts. Claude Code's own
    /// auto-compaction fires far later — `effectiveWindow - 33000`, i.e. ~96.6% — and fires
    /// mid-turn, so compacting here means compacting at a moment the app picked.
    public static let threshold: Double = 0.80

    /// Reading the transcript is the only pressure signal available, and it lags the live session
    /// by one assistant message; below this many tokens the reading is not worth acting on.
    public static let minimumUsefulTokens = 10_000

    /// Instructions passed to `/compact`. The default summariser keeps the narrative and drops the
    /// decisions; for an orchestrator almost everything narrative is re-readable from the board and
    /// the conversation with the human is not.
    public static let instructions = [
        "Preserve, in this order, and nothing else:",
        "1. Standing instructions from the human — anything phrased as a rule for how I work rather than a one-off request; quote them.",
        "2. Decisions the human made and the reason given, including ones that overruled me; a decision without its reason gets relitigated.",
        "3. Questions I put to the human that are still unanswered, verbatim, each with what it blocks.",
        "4. Anything suspending normal behaviour and not yet lifted: shutdown orders, tasks filed as do-not-execute, spawns deliberately withheld.",
        "5. Facts established by measurement this session that are not written down in the repo — what was measured, the result, and where it is or is not recorded; mark inferred facts inferred.",
        "6. Things I asserted and got wrong, reduced to the correct fact; keep the fact, drop the story.",
        "7. Git state the board does not show: which branches are merged into the base branch, which are not and why, and any file a future merge will conflict on again.",
        "8. Failure modes observed this session and the structural fix, if one landed.",
        "Delete entirely, do not summarise:",
        "every enumeration of tasks, columns, epics, agents, costs or token counts (all stale on arrival and re-readable from the board);",
        "file contents, diffs, build output, test counts, tool results;",
        "worker report bodies;",
        "the narrative of what I did, in what order, or how I found something;",
        "anything already written into SPEC.md, CLAUDE.md, README.md or a ticket body — keep a pointer, never the content.",
        "Write it as instructions to myself: imperative, present tense.",
        "No line may carry a number that will be wrong in five minutes; where a count matters, name the tool that returns it instead.",
        "End with a section headed \"unrecorded — write this down\" listing any fact above that belongs in a ticket, a note or SPEC.md and is not there yet.",
    ].joined(separator: " ")

    /// A compacted session sits idle exactly like a resumed one (§9), and wakes up not knowing what
    /// it was doing. This is the fixed first turn that points it back at the board.
    public static let reorientation =
        "[agent-board] This session was compacted. The board is in SQLite and survived: "
        + "call list_tasks, list_agents and list_reports to re-read it before doing anything else."

    /// What Agent Board types to start a compaction. Its carriage return is deliberately absent —
    /// see `TerminalPromptInput`'s note on slash commands.
    public static var command: String { "/compact " + instructions }
}
