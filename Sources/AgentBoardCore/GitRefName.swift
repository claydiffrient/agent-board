import Foundation

/// The well-formedness half of every branch check in this codebase, shared so the local guard
/// (`PublishPolicy`) and the remote guard (`RemoteRefPolicy`) cannot drift apart on what git will
/// accept.
public enum GitRefName {
    /// Characters git itself refuses in a ref, plus the ones a push argument would read as
    /// something other than a branch (`:` splits a refspec, a leading `-` reads as an option).
    public static let forbidden: Set<Character> = [":", "?", "*", "[", "\\", "^", "~", " ", "\t", "\n"]

    public static func isWellFormed(_ branch: String) -> Bool {
        guard !branch.isEmpty, !branch.hasPrefix("-"), !branch.hasPrefix("/"), !branch.hasSuffix("/"),
              !branch.hasSuffix("."), !branch.hasSuffix(".lock"), !branch.contains(".."),
              !branch.contains("//"), !branch.contains("@{"), branch != "@"
        else { return false }
        return !branch.contains(where: { forbidden.contains($0) || $0.asciiValue.map { $0 < 0x20 || $0 == 0x7F } == true })
    }
}
