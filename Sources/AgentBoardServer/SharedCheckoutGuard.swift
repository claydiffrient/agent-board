import Foundation

/// Keeps a co-resident agent from reaching past its own files into the rest of the shared tree.
///
/// Two failures, one mechanism. `git commit -a`, or a bare `git commit` over a staged sibling's
/// file, sweeps another task's in-progress edits into this task's commit. `git stash`, `git
/// checkout .` and `git reset --hard` are worse: they destroy those edits outright, and nothing
/// the agent can do afterwards brings them back. The per-file locks do not cover either one —
/// they guard writes through the edit tools, and `Bash` takes no lock because a shell command's
/// target is not knowable from its text.
///
/// The deny is the same `PreToolUse` mechanism `IntegrationGuard` uses, which is the only thing
/// measured to stop an unattended `--permission-mode auto` worker. Matching is over a tokenized
/// command, not a shell AST: a base64'd or wrapper-scripted invocation gets through. This is
/// defence against an accident, not against an agent that is trying.
public enum SharedCheckoutGuard {
    public static let commitToolName = "commit_my_work"

    /// A git subcommand a shared-checkout worker must not run.
    public enum Violation: String, Sendable, Equatable, CaseIterable {
        case commit
        case stash
        case checkout
        case restore
        case reset
        case clean
        case remove
        case sparseCheckout
        case switchBranch
        case merge
        case rebase
        case pull
        case cherryPick
        case revert
        case applyMailbox
        case bisect

        /// The word as it is typed, which is what the agent sees in the denial.
        public var gitCommand: String {
            switch self {
            case .commit: return "commit"
            case .stash: return "stash"
            case .checkout: return "checkout"
            case .restore: return "restore"
            case .reset: return "reset"
            case .clean: return "clean"
            case .remove: return "rm"
            case .sparseCheckout: return "sparse-checkout"
            case .switchBranch: return "switch"
            case .merge: return "merge"
            case .rebase: return "rebase"
            case .pull: return "pull"
            case .cherryPick: return "cherry-pick"
            case .revert: return "revert"
            case .applyMailbox: return "am"
            case .bisect: return "bisect"
            }
        }

        init?(gitCommand: String) {
            guard let match = Violation.allCases.first(where: { $0.gitCommand == gitCommand }) else { return nil }
            self = match
        }

        /// Every denial names the thing to do instead. A bare refusal leaves the agent stuck, and a
        /// stuck agent works around the guard rather than stopping.
        public var reason: String {
            switch self {
            case .commit:
                return """
                    Agent Board blocks `git commit` in a shared checkout: another agent is working in this \
                    same tree, and a commit here would carry its unfinished edits under your task. Call the \
                    \(SharedCheckoutGuard.commitToolName) MCP tool with your message instead. Agent Board commits exactly the \
                    files you have written — it knows them from the locks your writes took — and tags the \
                    commit with your task id so your work stays reviewable on its own.
                    """
            case .stash:
                return """
                    Agent Board blocks `git stash` in a shared checkout. It takes the whole working tree, \
                    so it would sweep away every other agent's uncommitted work in this same directory, \
                    and `git stash pop` would drop an arbitrary tree back on top of theirs. To put your own \
                    work somewhere safe, call \(SharedCheckoutGuard.commitToolName)(message) — it commits only the files you \
                    hold, and you may call it more than once. To see the tree without your changes, use \
                    `git diff` or `git show`, which change nothing.
                    """
            case .checkout:
                return """
                    Agent Board blocks `git checkout` in a shared checkout. `git checkout .` and `git \
                    checkout -- <path>` discard working-tree changes, and most of the changed files here \
                    belong to the other agents in this tree; `git checkout <branch>` moves the branch all \
                    of them are committing to. To throw away your own edits to one file, run `git restore \
                    -- <path>` naming a file you have written — that exact form is allowed. The shared \
                    branch is Agent Board's to move, not yours.
                    """
            case .restore:
                return """
                    Agent Board allows `git restore` in a shared checkout only as `git restore -- <path>`, \
                    naming files your own writes have locked, as one plain command with no `&&`, no pipe \
                    and no `-C`. Any wider form — no pathspec, `.`, a glob, another agent's file — discards \
                    work that is not yours and cannot be recovered. Name your own files explicitly. To see \
                    what you would be throwing away first, `git diff -- <path>`.
                    """
            case .reset:
                return """
                    Agent Board blocks `git reset` in a shared checkout. `--hard`, `--merge` and `--keep` \
                    overwrite the working tree the other agents are editing, and every form moves HEAD on \
                    the branch all of them are committing to. To undo your own edit to one file, run `git \
                    restore -- <path>` naming a file you have written. A commit that should not have \
                    happened is a human's to unwind, not yours — say so in report_complete.
                    """
            case .clean:
                return """
                    Agent Board blocks `git clean` in a shared checkout. It deletes untracked files, and \
                    the untracked files here are mostly the other agents' new work, which has never been \
                    committed anywhere. `git status --porcelain` lists what is untracked without deleting \
                    anything, and plain `rm <path>` removes a file you created yourself.
                    """
            case .remove:
                return """
                    Agent Board blocks `git rm` in a shared checkout: it deletes from the working tree and \
                    stages the deletion in the index every agent here shares. Delete your own file with \
                    plain `rm <path>` and then call \(SharedCheckoutGuard.commitToolName)(message) — Agent Board records a \
                    deletion for any path you hold a lock on.
                    """
            case .sparseCheckout:
                return """
                    Agent Board blocks `git sparse-checkout` in a shared checkout: it removes tracked files \
                    from the working tree the other agents are editing. Leave the checkout's shape alone \
                    and work on the files your task needs; `git ls-files` and `git grep` search the repo \
                    without changing what is on disk.
                    """
            case .switchBranch:
                return """
                    Agent Board blocks `git switch` in a shared checkout. The branch is the group's: moving \
                    it takes the other agents with you, and their uncommitted work is either dragged along \
                    or the switch is refused because of it. You are already on the branch your task belongs \
                    on — commit to it with \(SharedCheckoutGuard.commitToolName)(message).
                    """
            case .merge, .rebase, .pull, .cherryPick, .revert, .applyMailbox, .bisect:
                return """
                    Agent Board blocks `git \(gitCommand)` in a shared checkout: it rewrites this whole \
                    working tree and moves the branch every agent here is committing to, and a conflict \
                    leaves their files full of markers they did not put there. Commit your own files with \
                    \(SharedCheckoutGuard.commitToolName)(message) and call report_complete; bringing this branch together \
                    with anything else is Agent Board's step, run once your task is accepted.
                    """
            }
        }
    }

    public enum Verdict: Sendable, Equatable {
        case allow
        case deny(Violation)
        /// `git restore` limited to an explicit pathspec, as one plain command. Allowed only if
        /// every path is one this session holds a lock on — which the guard cannot see, so the
        /// caller checks it and denies with `restoreOutOfScopeReason` when it does not hold.
        case restoreScoped(paths: [String])
    }

    /// What this command is, by text alone. The caller applies "is this a shared worker" on top;
    /// a worktree worker owns its tree and keeps every one of these commands.
    public static func inspect(toolName: String?, command: String?) -> Verdict {
        let invocations = IntegrationGuard.gitInvocations(toolName: toolName, command: command)
        for invocation in invocations {
            guard let violation = Violation(gitCommand: invocation.subcommand) else { continue }
            guard violation == .restore,
                  invocations.count == 1,
                  !invocation.relocated,
                  let command, isPlainCommand(command),
                  let paths = restorePathspec(invocation.arguments)
            else { return .deny(violation) }
            return .restoreScoped(paths: paths)
        }
        return .allow
    }

    /// Kept for the call site that predates the wider guard.
    public static func deniesCommit(toolName: String?, command: String?) -> Bool {
        inspect(toolName: toolName, command: command) == .deny(.commit)
    }

    public static let commitReason = Violation.commit.reason

    public static func restoreOutOfScopeReason(_ paths: [String]) -> String {
        let named = paths.map { "`\($0)`" }.joined(separator: ", ")
        return """
            Agent Board blocks this `git restore`: \(named) \(paths.count == 1 ? "is not a file" : "are not files") \
            this session has written, so \(paths.count == 1 ? "it belongs" : "they belong") to another agent in \
            this shared checkout or to nobody, and restoring \(paths.count == 1 ? "it" : "them") would destroy \
            work that is not yours. `git restore -- <path>` is allowed only for files your own writes have \
            locked. If you need that file changed and it is not yours, call report_blocked naming it.
            """
    }

    /// The pathspec after an explicit `--`, or nil when the command does not have that exact shape.
    /// Only the `--` form is accepted: without it a bare word may be a branch, a tree-ish or a
    /// pathspec depending on flags nobody should have to reason about at a deny.
    private static func restorePathspec(_ arguments: [String]) -> [String]? {
        guard !arguments.contains(where: { $0.hasPrefix("--pathspec-from-file") }) else { return nil }
        guard let separator = arguments.firstIndex(of: "--") else { return nil }
        let paths = Array(arguments[(separator + 1)...])
        guard !paths.isEmpty else { return nil }
        return paths
    }

    /// One command, no shell in it. Anything else and a path's meaning depends on a `cd`, a
    /// substitution or a quote that the tokenizer has already thrown away, so the scoped form is
    /// not offered for it.
    private static func isPlainCommand(_ command: String) -> Bool {
        !command.contains(where: { "&;|()<>$\"'`\\\n".contains($0) })
    }
}
