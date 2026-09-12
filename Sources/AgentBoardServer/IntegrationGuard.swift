import Foundation

/// The second enforcement of D8 (§8): Agent Board denies push and pull-request calls in its own
/// process, so the block holds under `--permission-mode auto`, where an `autoMode` classifier rule
/// has no user to ask and therefore never stops the call.
public enum IntegrationGuard {
    public enum Violation: String, Sendable, Equatable, CaseIterable {
        case push
        case pullRequestCreate
        case pullRequestMerge

        public var reason: String {
            switch self {
            case .push:
                return "Agent Board blocks pushes from workers. Commit on your branch and call report_complete; a human integrates it."
            case .pullRequestCreate:
                return "Agent Board blocks opening pull requests from workers. Commit on your branch and call report_complete; opening the pull request is the human's call."
            case .pullRequestMerge:
                return "Agent Board blocks merging pull requests from workers. Integration always requires human approval in Agent Board."
            }
        }
    }

    /// `git` global options that consume the following word, so a subcommand scan does not mistake
    /// their value for the subcommand.
    private static let gitValueFlags: Set<String> = ["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path"]

    /// Mirrors `SpawnRequest.defaultDisallowedTools`. Scans the whole command, so a chained, wrapped,
    /// or env-prefixed invocation (`cd x && git push`, `GIT_SSH_COMMAND=... git -C d push`) is caught too.
    public static func violation(toolName: String?, command: String?) -> Violation? {
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
