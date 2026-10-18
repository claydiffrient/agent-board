import Foundation

/// What tearing worktrees down had to say. `notices` reach the status bar, as every cleanup notice
/// always has; `findings` — a worktree kept, or a teardown hook that failed — also go on the task
/// and into the decision report for the removal (SPEC §5).
struct WorktreeCleanup: Sendable {
    struct Finding: Sendable {
        var path: String
        var text: String
    }

    var notices: [String] = []
    var findings: [Finding] = []

    mutating func add(_ text: String, at path: String) {
        notices.append(text)
        findings.append(Finding(path: path, text: text))
    }
}
