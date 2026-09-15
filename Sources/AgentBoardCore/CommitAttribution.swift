import Foundation

/// How a commit says which task made it.
///
/// A worktree task is identified by its branch, `agentboard/<task-id>`. On a shared branch two
/// tasks' commits interleave on one ref, so the branch name can no longer carry the mapping and a
/// trailer does instead: it is part of the commit object, so it survives a merge, a cherry-pick and
/// the branch deletion that accepting a task performs.
public enum CommitAttribution {
    public static let trailerKey = "Agent-Board-Task"

    public static func trailer(taskId: String) -> String { "\(trailerKey): \(taskId)" }

    /// `body` with the trailer appended, or unchanged when it already ends with this task's trailer.
    ///
    /// Git only reads trailers out of the message's last paragraph, so the trailer is separated by
    /// a blank line unless the body's own last line is already a trailer.
    public static func message(_ body: String, taskId: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = trailer(taskId: taskId)
        guard !trimmed.isEmpty else { return line }
        let lines = trimmed.components(separatedBy: "\n")
        if lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == line }) { return trimmed }
        let lastParagraphIsTrailers = lines.count > 1
            && lines.suffix(while: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }).allSatisfy(isTrailerLine)
        return trimmed + (lastParagraphIsTrailers ? "\n" : "\n\n") + line
    }

    /// The task id carried by a parsed trailer value, or nil when the value is not one.
    public static func taskId(trailerValue: String) -> String? {
        let value = trailerValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func isTrailerLine(_ line: String) -> Bool {
        guard let colon = line.firstIndex(of: ":") else { return false }
        let key = line[line.startIndex..<colon]
        return !key.isEmpty && key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }
}

private extension Array where Element == String {
    func suffix(while predicate: (String) -> Bool) -> [String] {
        var result: [String] = []
        for line in reversed() {
            guard predicate(line) else { break }
            result.append(line)
        }
        return result
    }
}
