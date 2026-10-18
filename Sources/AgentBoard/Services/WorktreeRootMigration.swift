import AgentBoardCore
import AgentBoardRuntime
import Foundation
import GRDB

/// Rewrites a worktree root that still contains a space — the old Application Support default — to
/// `worktreeBase/<project-id>`, but only once git lists no worktree under it (SPEC §4). The reaper
/// only looks under the current root, so moving the root past a live worktree would orphan it.
///
/// This is launch-time reconciliation rather than a GRDB migration: it has to run `git worktree
/// list`, and a project skipped today must be retried on every later launch until its worktrees are
/// gone, while a schema migration runs once and is recorded as applied.
struct WorktreeRootMigration: Sendable {
    var db: AppDatabase
    var worktreeBase: URL
    var home: URL

    struct Outcome: Sendable, Equatable {
        var migrated: [String] = []
        var skipped: [String] = []

        var isEmpty: Bool { migrated.isEmpty && skipped.isEmpty }
    }

    func run() -> Outcome {
        var outcome = Outcome()
        guard let all = try? ProjectStore(db).list() else { return outcome }

        for project in all where !WorktreeRootRule.isValid(project.worktreeRoot) {
            let destination = worktreeBase.appendingPathComponent(project.id)
            guard WorktreeRootRule.isValid(destination.path) else {
                outcome.skipped.append(
                    "\(project.name): the new worktree base \(destination.path) also contains a space"
                )
                continue
            }
            let remaining: [String]
            do {
                remaining = try worktrees(of: project)
            } catch {
                outcome.skipped.append(
                    "\(project.name): its worktree root is unchanged because its worktrees could not be listed: \(describe(error))"
                )
                continue
            }
            guard remaining.isEmpty else {
                outcome.skipped.append(
                    "\(project.name) keeps the worktree root \(project.worktreeRoot) while these worktrees are under it: "
                        + remaining.joined(separator: ", ")
                        + ". Finish or remove them, and the next launch moves the root to \(destination.path)."
                )
                continue
            }
            do {
                try setWorktreeRoot(project.id, destination.path)
                outcome.migrated.append("\(project.name) → \(destination.path)")
            } catch {
                outcome.skipped.append("\(project.name): \(describe(error))")
            }
        }
        return outcome
    }

    private func worktrees(of project: Project) throws -> [String] {
        let root = resolved(WorktreeRootRule.url(project.worktreeRoot, home: home))
        let manager = WorktreeManager(
            repoPath: URL(fileURLWithPath: project.repoPath), worktreeRoot: worktreeBase, attribution: .unattributable
        )
        return try manager.list()
            .map { resolved($0.path) }
            .filter { $0 == root || $0.hasPrefix(root + "/") }
    }

    /// `git worktree list` prints /private/var where a caller may have stored /var.
    private func resolved(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func setWorktreeRoot(_ id: String, _ path: String) throws {
        try db.writer.write { db in
            try db.execute(sql: "UPDATE project SET worktree_root = ? WHERE id = ?", arguments: [path, id])
        }
    }

    private func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}
