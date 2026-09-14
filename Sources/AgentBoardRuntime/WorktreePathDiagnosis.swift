import Foundation

public struct WorktreePathWarning: Sendable, Equatable {
    public var path: String
    /// Names of the offending characters, splitting ones first, without repeats.
    public var found: [String]
    public var message: String
}

/// Evidence that a path was word-split by a shell rather than genuinely missing.
public struct SplitPathEvidence: Sendable, Equatable {
    /// The part of the worktree path the shell kept as its own word.
    public var prefix: String
    /// Name of the character the path was split at, as it reads mid-sentence ("a space").
    public var hazard: String
    public var line: String
}

/// Recognises worktree paths that a repository's setup will mishandle when it interpolates them
/// into a shell command unquoted, before the spawn and again in the failure it produces.
public enum WorktreePathDiagnosis {
    private typealias Hazard = (character: Character, name: String)

    /// Characters `sh` splits an unquoted word on: the ones that turn one path into several
    /// arguments and drop the tail.
    private static let splitting: [Hazard] = [
        (" ", "a space"),
        ("\t", "a tab"),
        ("\n", "a newline"),
    ]

    /// Characters that survive splitting but still change what an unquoted path means.
    private static let expanding: [Hazard] = [
        ("$", "a dollar sign"),
        ("`", "a backtick"),
        ("\"", "a double quote"),
        ("'", "a single quote"),
        ("\\", "a backslash"),
        ("*", "an asterisk"),
        ("?", "a question mark"),
        ("[", "an opening bracket"),
        ("&", "an ampersand"),
        (";", "a semicolon"),
        ("|", "a pipe"),
        ("<", "a less-than sign"),
        (">", "a greater-than sign"),
        ("(", "an opening parenthesis"),
        (")", "a closing parenthesis"),
    ]

    private static let missingFileMarker = "No such file or directory"

    public static func preflight(worktreePath: String) -> WorktreePathWarning? {
        var found: [String] = []
        for hazard in splitting + expanding where worktreePath.contains(hazard.character) {
            found.append(hazard.name)
        }
        guard !found.isEmpty else { return nil }
        let list = phrase(found)
        return WorktreePathWarning(
            path: worktreePath,
            found: found,
            message: """
            Worktree path \(worktreePath) contains \(list). A repository whose setup shells out \
            without quoting the path — a `post-checkout` hook that runs a build, say — will fail in \
            this worktree before the agent starts. Move this project's worktree root to a path \
            without it.
            """
        )
    }

    /// The `No such file or directory` a shell reports for part of `worktreePath` after splitting
    /// it. A line naming the whole path is a genuinely missing file and is not evidence.
    public static func splitPath(worktreePath: String, output: String) -> SplitPathEvidence? {
        let candidates = splitCandidates(in: worktreePath)
        guard !candidates.isEmpty else { return nil }
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            guard text.contains(missingFileMarker) else { continue }
            for candidate in candidates
            where text.contains(candidate.prefix)
                && !text.contains(candidate.prefix + String(candidate.character)) {
                return SplitPathEvidence(prefix: candidate.prefix, hazard: candidate.name, line: text)
            }
        }
        return nil
    }

    /// Prepends one line naming the cause when `output` carries the signature of a split worktree
    /// path, and returns `output` untouched when it does not — a wrong guess that buries the real
    /// error is worse than no guess.
    public static func explain(_ output: String, worktreePath: String) -> String {
        guard let evidence = splitPath(worktreePath: worktreePath, output: output) else { return output }
        let headline = """
        Setup failed on the worktree path, not on anything in the repository: it contains \
        \(evidence.hazard), and the setup shelled out with it unquoted, so the shell saw only \
        "\(evidence.prefix)". Move this project's worktree root to a path without it; the full \
        output follows.
        """
        return headline + "\n\n" + output
    }

    /// Every prefix of `path` that ends where a shell would split it, deepest first so the most
    /// specific match in a line wins.
    private static func splitCandidates(in path: String) -> [(prefix: String, character: Character, name: String)] {
        var candidates: [(prefix: String, character: Character, name: String)] = []
        for (offset, character) in path.enumerated() {
            guard let hazard = splitting.first(where: { $0.character == character }) else { continue }
            let prefix = String(path.prefix(offset))
            guard prefix.contains("/") else { continue }
            candidates.append((prefix, hazard.character, hazard.name))
        }
        return candidates.reversed()
    }

    private static func phrase(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", and " + items[items.count - 1]
        }
    }
}
