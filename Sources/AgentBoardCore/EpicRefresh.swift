import Foundation

/// How far an epic branch has moved from the project's base branch (SPEC §5.2). Reported, never
/// alarmed on: nothing raises the attention signal or a notification from it.
public enum BaseDrift: Sendable, Equatable {
    /// `behind` counts the base's commits the epic branch lacks; `ahead`, the epic's the base lacks.
    case measured(behind: Int, ahead: Int)
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

    public init(kind: Kind, command: String, status: Int32, outputTail: String = "") {
        self.kind = kind
        self.command = command
        self.status = status
        self.outputTail = outputTail
    }

    public var passed: Bool { status == 0 }
}

/// What `refresh_epic` did (SPEC §5.2). Every case but `refreshed` and `alreadyCurrent` leaves the
/// epic branch exactly where it was.
public enum EpicRefresh: Sendable, Equatable {
    case alreadyCurrent(head: String)
    /// `passed` is every configured command, all green; `unverified` is what nothing was
    /// configured for, and so was never run.
    case refreshed(previousHead: String, head: String, passed: [RefreshCheck], unverified: [RefreshCheck.Kind])
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
        case .alreadyCurrent, .refreshed, .noEpicBranch: return false
        case .conflicted, .verificationFailed, .checkedOut, .moved, .noBaseBranch: return true
        }
    }

    private static let humanDecides = "Whether you fix it yourself or dispatch a task for it is the human's call: ask them."

    public func message(branch: String, base: String) -> String {
        switch self {
        case .alreadyCurrent(let head):
            return "\(branch) already has every commit on \(base); nothing was merged. It is at \(short(head))."
        case let .refreshed(previous, head, passed, unverified):
            var text = "Merged \(base) into \(branch): it moved from \(short(previous)) to \(short(head))."
            if !passed.isEmpty {
                text += " Verified on the merge result before the branch moved: "
                    + passed.map { "`\($0.command)` passed" }.joined(separator: ", then ") + "."
            }
            if !unverified.isEmpty {
                text += " " + Self.unverifiedClause(unverified, branch: branch, previous: previous)
            }
            return text
        case let .conflicted(head, files):
            return "Refresh refused: merging \(base) into \(branch) conflicts in \(files.count) file(s): "
                + files.joined(separator: ", ") + ". \(branch) is untouched at \(short(head)). " + Self.humanDecides
        case let .verificationFailed(head, candidate, failure, passed):
            var text = "Refresh failed: \(base) merged into \(branch) without conflicts, but "
            if !passed.isEmpty { text += passed.map { "`\($0.command)` passed and " }.joined() }
            text += "`\(failure.command)` exited \(failure.status) on the result. \(branch) was not moved: it is "
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
