import Foundation

/// The Coordinator's folder and file reach (SPEC §8.2): it runs in its own folder with the human's
/// home added, and every registered repository is read-only to it.
public enum CoordinatorHome {
    public static let claudeMdName = "CLAUDE.md"

    /// Creates the folder and seeds `CLAUDE.md` only when there is none, so a file the human has
    /// edited, or replaced, is never touched.
    public static func prepare(_ dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let claudeMd = dir.appendingPathComponent(claudeMdName)
        guard !FileManager.default.fileExists(atPath: claudeMd.path) else { return }
        try Data(starterClaudeMd.utf8).write(to: claudeMd, options: .withoutOverwriting)
    }

    /// One `Edit` deny per path. Claude Code applies an `Edit` rule to Write, MultiEdit and
    /// NotebookEdit, to the file commands it recognizes in Bash (`sed`, `tee`) and to redirection
    /// targets; `//` marks the pattern as absolute. A symlinked path is denied under both spellings.
    public static func denyRules(readOnlyPaths: [String]) -> [String] {
        var seen: Set<String> = []
        var rules: [String] = []
        for path in readOnlyPaths where !path.isEmpty {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            for spelling in [path, resolved] {
                let trimmed = spelling.hasSuffix("/") ? String(spelling.dropLast()) : spelling
                let rule = "Edit(/\(trimmed)/**)"
                if seen.insert(rule).inserted { rules.append(rule) }
            }
        }
        return rules
    }

    public static let starterClaudeMd = """
    # Coordinator

    You are the Agent Board Coordinator: a Claude Code session that belongs to no project. The human uses you for one-off work that does not need a board, and for planning and coordinating work that spans projects.

    ## What you can and cannot do

    - **You read every board and write none.** The `agent-board` tools let you read any project's tasks, epics, notes, agent sessions and pending approvals. They refuse every write.
    - **Every registered project's repository is read-only to you, by any means.** Agent Board denies edits inside them, rebuilt from the project list each time a session starts — but that rule does not stop `git commit`, `git checkout`, `mv`, `cp`, `rm`, an interpreter (`python -c`, `node -e`), or a build tool run in Bash. Never use those inside a registered repo or its worktree either. Reading those repos, and editing anywhere else under home, stays allowed. Outside those repositories you are an ordinary session: your home directory is writable, so dotfiles and other one-off jobs are fine.
    - **Changes to a project go through its orchestrator, by request.** When a board or a repository needs changing, ask that project's orchestrator. It normally acts, within its board's own rules, and it may decline with a reason. Either way it replies.
    - **Messages are ephemeral.** Requests and replies are working traffic and are deleted once closed. Anything that must outlive them, such as a cross-project plan, goes into a plan note.

    This file is yours to edit. Agent Board writes it only when it is missing.

    """
}
