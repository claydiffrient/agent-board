import Foundation

/// The second enforcement of D8 (§8): Agent Board denies push and pull-request calls in its own
/// process, so the block holds under `--permission-mode auto`, where an `autoMode` classifier rule
/// has no user to ask and therefore never stops the call.
///
/// The verdict is scoped at the grant (D4), not the prompt. A worker grant is denied all three
/// shapes. An orchestrator grant may push and open a pull request — through `push_branch` and
/// `open_pull_request`, which queue a human approval — and is still denied `gh pr merge`.
public enum IntegrationGuard {
    public enum Violation: String, Sendable, Equatable, CaseIterable {
        case push
        case pullRequestCreate
        case pullRequestMerge

        /// Denied for a worker grant only; an orchestrator reaches the remote through the
        /// approval-gated tools instead.
        public var isWorkerOnly: Bool { self != .pullRequestMerge }

        public var reason: String { reason(for: .worker) }

        public func reason(for scope: TokenScope) -> String {
            switch (self, scope) {
            case (.push, .worker):
                return "Agent Board blocks pushes from workers. Commit on your branch and call report_complete; a human integrates it."
            case (.pullRequestCreate, .worker):
                return "Agent Board blocks opening pull requests from workers. Commit on your branch and call report_complete; opening the pull request is the human's call."
            case (.pullRequestMerge, .worker):
                return "Agent Board blocks merging pull requests from workers. Integration always requires human approval in Agent Board."
            case (.push, .orchestrator):
                return "Agent Board blocks pushing from the shell. Call push_branch(branch); it queues an approval the human grants."
            case (.pullRequestCreate, .orchestrator):
                return "Agent Board blocks opening pull requests from the shell. Call open_pull_request(epic_id or branch, title, body); it queues an approval the human grants."
            case (.pullRequestMerge, .orchestrator):
                return "Agent Board blocks merging pull requests. Merging a pull request is the human's call and there is no tool for it."
            }
        }
    }

    /// `git` global options that consume the following word, so a subcommand scan does not mistake
    /// their value for the subcommand.
    private static let gitValueFlags: Set<String> = ["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path"]

    /// Mirrors `SpawnRequest.defaultDisallowedTools`. Scans the whole command, so a chained, wrapped,
    /// or env-prefixed invocation (`cd x && git push`, `GIT_SSH_COMMAND=... git -C d push`) is caught too.
    /// `scope` decides which matches are violations; the scan itself is the same for both.
    public static func violation(toolName: String?, command: String?, scope: TokenScope = .worker) -> Violation? {
        guard let match = match(toolName: toolName, command: command) else { return nil }
        guard scope == .worker || !match.isWorkerOnly else { return nil }
        return match
    }

    /// What the command is, regardless of who is calling. `violation` applies the scope on top.
    public static func match(toolName: String?, command: String?) -> Violation? {
        guard toolName == "Bash", let command, !command.isEmpty else { return nil }
        let words = tokens(command)
        for index in words.indices {
            switch words[index] {
            case "git":
                if subcommand(after: index, in: words)?.word == "push" { return .push }
            case "gh":
                guard let pr = subcommand(after: index, in: words), pr.word == "pr" else { continue }
                switch subcommand(after: pr.index, in: words)?.word {
                case "create": return .pullRequestCreate
                case "merge": return .pullRequestMerge
                default: continue
                }
            default:
                continue
            }
        }
        return nil
    }

    /// Whether the command invokes `git <subcommand>` anywhere in it, by the same scan `match` uses,
    /// so a chained or env-prefixed invocation is seen too.
    public static func invokesGit(_ subcommand: String, toolName: String?, command: String?) -> Bool {
        guard toolName == "Bash", let command, !command.isEmpty else { return false }
        let words = tokens(command)
        for index in words.indices where words[index] == "git" {
            if self.subcommand(after: index, in: words)?.word == Substring(subcommand) { return true }
        }
        return false
    }

    private static func subcommand(after index: Int, in words: [Substring]) -> (word: Substring, index: Int)? {
        var cursor = index + 1
        while cursor < words.count {
            let word = words[cursor]
            guard word.hasPrefix("-") else { return (word, cursor) }
            cursor += gitValueFlags.contains(String(word)) ? 2 : 1
        }
        return nil
    }

    /// Splits on shell punctuation as well as whitespace so `&&`, `;`, `|`, quotes and parentheses
    /// cannot hide a `git push` from the scan.
    private static func tokens(_ command: String) -> [Substring] {
        command.split(whereSeparator: { $0.isWhitespace || "&;|()\"'`\\".contains($0) })
    }
}
