import AgentBoardCore
import AgentBoardRuntime
import Foundation
import GRDB

/// Relocates projects whose worktree root still contains a space onto `worktreeBase`.
///
/// This is launch-time reconciliation rather than a GRDB migration because the work is mostly on
/// disk — `git worktree move` per live worktree — and a schema migration cannot shell out, cannot
/// be skipped per project when a worker is running, and cannot be retried on a later launch once
/// its identifier is recorded as applied.
struct WorktreeRootMigration: Sendable {
    var db: AppDatabase
    var worktreeBase: URL

    struct Outcome: Sendable, Equatable {
        var migrated: [String] = []
        var skipped: [String] = []
        var notices: [String] = []

        var isEmpty: Bool { migrated.isEmpty && skipped.isEmpty && notices.isEmpty }
    }

    func run() -> Outcome {
        var outcome = Outcome()
        let projects = ProjectStore(db)
        let sessions = SessionStore(db)
        guard let all = try? projects.list() else { return outcome }

        for project in all {
            guard !WorktreeRootRule.isValid(project.worktreeRoot) else { continue }
            let destination = worktreeBase.appendingPathComponent(project.id)
            guard WorktreeRootRule.isValid(destination.path) else {
                outcome.skipped.append(
                    "\(project.name): the new worktree base \(destination.path) also contains a space"
                )
                continue
            }
            if let active = try? sessions.active(projectId: project.id), !active.isEmpty {
                outcome.skipped.append(
                    "\(project.name): \(active.count) session(s) still running; its worktree root is unchanged"
                )
                continue
            }
            do {
                outcome.notices += try relocate(project, to: destination)
                try setWorktreeRoot(project.id, destination.path)
                outcome.migrated.append("\(project.name) → \(destination.path)")
            } catch {
                outcome.skipped.append("\(project.name): \(describe(error))")
            }
        }
        return outcome
    }

    /// Moves every live worktree git knows about that still sits under the old root. Anything else
    /// in the old directory — a stale checkout git has forgotten, say — is left where it is and
    /// reported, since moving it blind is how work gets lost.
    private func relocate(_ project: Project, to destination: URL) throws -> [String] {
        let oldRoot = URL(fileURLWithPath: project.worktreeRoot).standardizedFileURL
        let repo = URL(fileURLWithPath: project.repoPath)
        guard FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git").path) else {
            return ["\(project.name): \(repo.path) is no longer a git repository; only the recorded root moved"]
        }
        let manager = WorktreeManager(repoPath: repo, worktreeRoot: destination, attribution: .unattributable)
        var notices: [String] = []
        for worktree in try manager.list() where isUnder(worktree.path, oldRoot) {
            let target = destination.appendingPathComponent(worktree.path.lastPathComponent)
            if FileManager.default.fileExists(atPath: target.path) {
                notices.append("\(project.name): \(target.path) already exists; \(worktree.path.path) was left in place")
                continue
            }
            try manager.move(worktree: worktree.path, to: target)
        }
        notices += leftBehind(in: oldRoot, project: project)
        return notices
    }

    private func leftBehind(in oldRoot: URL, project: Project) -> [String] {
        let fm = FileManager.default
        guard let remaining = try? fm.contentsOfDirectory(atPath: oldRoot.path) else { return [] }
        if remaining.isEmpty {
            try? fm.removeItem(at: oldRoot)
            return []
        }
        return ["\(project.name): \(remaining.count) director(y/ies) git does not track were left at \(oldRoot.path)"]
    }

    private func isUnder(_ path: URL, _ root: URL) -> Bool {
        let candidate = path.standardizedFileURL.path
        return candidate == root.path || candidate.hasPrefix(root.path + "/")
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
