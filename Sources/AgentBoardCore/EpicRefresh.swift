import Foundation

/// How far an epic branch has moved from the project's base branch (SPEC §5.2). Reported, never
/// alarmed on: nothing raises the attention signal or a notification from it.
public enum BaseDrift: Sendable, Equatable {
    /// `behind` counts the base's commits the epic branch lacks; `ahead`, the epic's the base lacks.
    /// `against` names the ref counted from, `origin/main` or `main`.
    case measured(behind: Int, ahead: Int, against: String)
    case noEpicBranch(String)
    case noBaseBranch(String)
    case unavailable(String)
}

/// One verification command a refresh ran against its merge result.
public struct RefreshCheck: Sendable, Equatable {
    public enum Kind: String, Sendable { case build, test }

    public var kind: Kind
    public var command: String
    public var status: Int32
    /// The end of the command's combined output, only kept for a failure.
    public var outputTail: String
    /// Set when the command was stopped, with its process group, for running this long.
    public var timedOutAfter: Int?

    public init(kind: Kind, command: String, status: Int32, outputTail: String = "", timedOutAfter: Int? = nil) {
        self.kind = kind
        self.command = command
        self.status = status
        self.outputTail = outputTail
        self.timedOutAfter = timedOutAfter
    }

    public var passed: Bool { status == 0 && timedOutAfter == nil }

    var outcomeClause: String {
        if let seconds = timedOutAfter {
            return "`\(command)` timed out after \(duration(seconds)) on the result and was stopped with its whole "
                + "process group (if it legitimately takes longer, the human can raise the refresh check timeout in "
                + "the project's Verification settings)"
        }
        return "`\(command)` exited \(status) on the result"
    }
}

/// A refresh's outcome and the ref it merged, which is `origin/<base>` whenever the fetch found
/// that at or ahead of local `<base>` (SPEC §5.2).
public struct EpicRefreshAnswer: Sendable, Equatable {
    public var outcome: EpicRefresh
    public var merged: String
    /// Set when the fetch failed, so local `<base>` was merged and may be behind.
    public var warning: String?

    public init(_ outcome: EpicRefresh, merged: String, warning: String? = nil) {
        self.outcome = outcome
        self.merged = merged
        self.warning = warning
    }

    public func message(branch: String) -> String {
        outcome.message(branch: branch, base: merged) + (warning.map { " \($0)" } ?? "")
    }
}

/// What `refresh_epic` did (SPEC §5.2). Every case but `refreshed` and `alreadyCurrent` leaves the
/// epic branch exactly where it was.
public enum EpicRefresh: Sendable, Equatable {
    case alreadyCurrent(head: String)
    /// The configured commands are running on `candidate` in the background; the outcome arrives
    /// as a `refresh` report. A cold build outlasts the 60 seconds Claude Code waits for a tool's
    /// answer, so the call cannot wait for it.
    case verifying(head: String, candidate: String, commands: [String], timeoutSeconds: Int)
    /// Another refresh of this epic is still verifying; nothing was started.
    case inProgress(candidate: String?)
    /// The board, not the merge, stopped the refresh before a verdict: its scratch checkout could
    /// not be set up, or Agent Board stopped mid-run.
    case interrupted(head: String, reason: String)
    /// `passed` is every command the project's policy runs, all green; `unverified` is what nothing
    /// was configured for, and so was never run; `testsLeftToCI` when the policy runs no tests.
    case refreshed(
        previousHead: String, head: String, passed: [RefreshCheck], unverified: [RefreshCheck.Kind],
        testsLeftToCI: Bool
    )
    case conflicted(head: String, files: [String])
    /// The merge was clean but did not build or pass its tests. `candidate` is on no branch.
    case verificationFailed(head: String, candidate: String, failure: RefreshCheck, passed: [RefreshCheck])
    case checkedOut(path: String, holder: String?)
    /// An acceptance landed on the epic branch while the merge was being verified.
    case moved(from: String, to: String)
    case noEpicBranch
    case noBaseBranch

    /// Terminal epics take no more work, so nothing is merged into their branch either.
    public static func refusal(for epic: Epic) -> String? {
        guard epic.state.isTerminal else { return nil }
        return "Epic \(epic.id) is \(epic.state.rawValue): it is closed, so its branch is not refreshed."
    }

    public var isFailure: Bool {
        switch self {
        case .alreadyCurrent, .refreshed, .noEpicBranch, .verifying: return false
        case .conflicted, .verificationFailed, .checkedOut, .moved, .noBaseBranch, .inProgress, .interrupted: return true
        }
    }

    private static let humanDecides = "Whether you fix it yourself or dispatch a task for it is the human's call: ask them."

    public func message(branch: String, base: String) -> String {
        switch self {
        case .alreadyCurrent(let head):
            return "\(branch) already has every commit on \(base); nothing was merged. It is at \(short(head))."
        case let .verifying(head, candidate, commands, timeout):
            return "Refresh started: \(base) merges into \(branch) cleanly as commit \(short(candidate)), and "
                + commands.map { "`\($0)`" }.joined(separator: " then ")
                + " now run\(commands.count == 1 ? "s" : "") on it in a scratch checkout, each stopped after "
                + "\(duration(timeout)). \(branch) stays at \(short(head)) until they pass. The outcome arrives as "
                + "a `refresh` report through list_reports; until then another refresh_epic for this epic is refused."
        case .inProgress(let candidate):
            return "Refresh refused: a refresh of \(branch) is already running"
                + (candidate.map { ", verifying commit \(short($0))" } ?? "")
                + ". Its outcome arrives as a `refresh` report through list_reports. Nothing new was started."
        case let .interrupted(head, reason):
            return "Refresh did not finish: \(reason). \(branch) was not moved: it is still at \(short(head)). "
                + "This is not a verdict on the merge — no build or test failed. Refresh again once the cause is dealt with."
        case let .refreshed(previous, head, passed, unverified, testsLeftToCI):
            var text = "Merged \(base) into \(branch): it moved from \(short(previous)) to \(short(head))."
            if !passed.isEmpty {
                text += " Verified on the merge result before the branch moved: "
                    + passed.map { "`\($0.command)` passed" }.joined(separator: ", then ") + "."
            }
            if !unverified.isEmpty {
                text += " " + Self.unverifiedClause(unverified, branch: branch, previous: previous)
            }
            if testsLeftToCI {
                text += " No tests ran: this project's integration verification setting leaves them to the epic's "
                    + "pull request CI."
            }
            return text
        case let .conflicted(head, files):
            return "Refresh refused: merging \(base) into \(branch) conflicts in \(files.count) file(s): "
                + files.joined(separator: ", ") + ". \(branch) is untouched at \(short(head)). " + Self.humanDecides
        case let .verificationFailed(head, candidate, failure, passed):
            var text = "Refresh failed: \(base) merged into \(branch) without conflicts, but "
            if !passed.isEmpty { text += passed.map { "`\($0.command)` passed and " }.joined() }
            text += failure.outcomeClause + ". \(branch) was not moved: it is "
                + "still at \(short(head)). The merge that failed is commit \(short(candidate)), which no branch holds. "
                + Self.humanDecides
            if !failure.outputTail.isEmpty { text += "\n\nEnd of its output:\n\(failure.outputTail)" }
            return text
        case let .checkedOut(path, holder):
            return "Refresh refused: \(branch) is checked out at \(path)" + (holder.map { " by \($0)" } ?? "")
                + ". Moving a checked-out branch leaves that working tree reporting the merged files as deleted, "
                + "and merging inside it would write into whoever is working there. Once nothing holds it, "
                + "refresh again — or have whoever holds it run `git merge \(base)` there. \(branch) is untouched."
        case let .moved(from, to):
            return "Refresh failed: \(branch) moved from \(short(from)) to \(short(to)) while the merge was being "
                + "verified, because a task was accepted into it. Nothing was applied; refresh again."
        case .noEpicBranch:
            return "Nothing to refresh: \(branch) does not exist yet. It is cut from \(base) when the epic's first "
                + "task is spawned or accepted, so it starts current."
        case .noBaseBranch:
            return "Refresh refused: the project's base branch \(base) does not exist in this repository, so "
                + "there is nothing to merge. \(branch) is untouched."
        }
    }

    /// Mirrors `VerificationCommands.integratorInstruction`: an unknown command is named as unknown
    /// and handed to the agent to work out, never reported as passing.
    private static func unverifiedClause(_ kinds: [RefreshCheck.Kind], branch: String, previous: String) -> String {
        let missing = kinds.count == 2 ? "no build or test command" : "no \(kinds[0].rawValue) command"
        let what = kinds.count == 2 ? "built or tested nothing" : (kinds[0] == .build ? "built nothing" : "ran no tests")
        let owed = kinds.count == 2 ? "build and test it" : (kinds[0] == .build ? "build it" : "run its tests")
        return "NOT VERIFIED: this project configures \(missing), so Agent Board \(what). A clean git merge is not "
            + "a build. Before you spawn from \(branch), \(owed) — work out how this project does it from its build "
            + "files, scripts and CI config — in a detached checkout (`git worktree add --detach <path> \(branch)`), "
            + "and tell the human exactly what you ran. If it breaks, the refresh caused it, not a task: \(branch) "
            + "was at \(short(previous)) before it."
    }
}

private func short(_ commit: String) -> String { String(commit.prefix(12)) }

private func duration(_ seconds: Int) -> String {
    seconds >= 60 && seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds)s"
}
