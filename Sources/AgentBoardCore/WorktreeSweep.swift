import Foundation
import GRDB

/// What Clean up worktrees would take in one project (SPEC §5, "Sweeping finished work's worktrees").
public struct WorktreeSweepScan: Sendable, Equatable {
    /// On disk and belonging to a done or closed task, or held by a done or abandoned epic.
    public var finished: [HeldWorktree]
    /// Directories under the worktree root that no session recorded and that are no epic's checkout or a slot.
    public var unknown: [String]
}

public struct WorktreeSweepResult: Sendable, Equatable {
    public var projectId: String
    public var removed: [String]
    public var kept: [WorktreeCleanupFinding]
    /// Teardown hooks that failed or timed out in a worktree that was still removed.
    public var teardownFailures: [WorktreeCleanupFinding]
    public var unknown: [String]
    /// The volume's free space after the sweep minus before it, floored at zero; nil when unreadable.
    public var bytesReclaimed: Int64?

    public init(
        projectId: String, removed: [String] = [], kept: [WorktreeCleanupFinding] = [],
        teardownFailures: [WorktreeCleanupFinding] = [], unknown: [String] = [], bytesReclaimed: Int64? = nil
    ) {
        self.projectId = projectId
        self.removed = removed
        self.kept = kept
        self.teardownFailures = teardownFailures
        self.unknown = unknown
        self.bytesReclaimed = bytesReclaimed
    }

    public var freed: String? {
        bytesReclaimed.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }

    public var summary: String {
        var lines = [removed.isEmpty
            ? "No worktree of finished work was removed."
            : "Removed \(removed.count) worktree(s)" + (freed.map { ", freeing about \($0)." } ?? ".")]
        if !kept.isEmpty {
            lines.append("Kept:\n" + kept.map { "- \($0.text)" }.joined(separator: "\n"))
        }
        if !teardownFailures.isEmpty {
            lines.append("Teardown hook problems:\n" + teardownFailures.map { "- \($0.text)" }.joined(separator: "\n"))
        }
        if !unknown.isEmpty {
            lines.append("Left alone, since no session records them:\n" + unknown.map { "- \($0)" }.joined(separator: "\n"))
        }
        return lines.joined(separator: "\n\n")
    }
}

extension Board {
    public func worktreeSweepScan(projectId: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> WorktreeSweepScan {
        let (scan, root, known) = try db.reader.read { db -> (WorktreeSweepScan, URL, Set<String>) in
            guard let project = try Project.fetchOne(db, key: projectId) else {
                throw BoardError.projectNotFound(projectId)
            }
            let root = WorktreeRootRule.url(project.worktreeRoot, home: home)
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT s.worktree_path, t.id, t.title, t.origin, t.column_name
                    FROM agent_session s LEFT JOIN task t ON t.id = s.task_id
                    WHERE s.project_id = ? AND s.worktree_path IS NOT NULL
                    ORDER BY s.started_at, s.rowid
                    """,
                arguments: [projectId]
            )
            var known: Set<String> = [Self.resolved(project.repoPath)]
            var candidates: [HeldWorktree] = []
            for row in rows {
                let path: String = row[0]
                known.insert(Self.resolved(path))
                let column: TaskColumn? = row[4]
                guard column == .done || column == .closed,
                      WorktreeSlot.index(ofPath: path, root: root.path) == nil
                else { continue }
                candidates.append(HeldWorktree(
                    path: path, taskId: row[1], taskTitle: row[2],
                    isIntegration: (row[3] as TaskOrigin?) == .integration
                ))
            }
            for epic in try Epic.filter(Column("project_id") == projectId).fetchAll(db) {
                known.insert(Self.resolved(root.appendingPathComponent(HeldWorktree.epicWorktreeName(epicId: epic.id)).path))
                guard epic.state == .done || epic.state == .abandoned else { continue }
                candidates += try Self.heldWorktrees(db, epicId: epic.id)
            }
            var seen: Set<String> = []
            let finished = candidates.filter {
                FileManager.default.fileExists(atPath: $0.path) && seen.insert(Self.resolved($0.path)).inserted
            }
            return (WorktreeSweepScan(finished: finished, unknown: []), root, known)
        }
        let children = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        let unknown = children
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { WorktreeSlot.index(ofPath: $0.path, root: root.path) == nil && !known.contains(Self.resolved($0.path)) }
            .map { root.appendingPathComponent($0.lastPathComponent).path }
            .sorted()
        return WorktreeSweepScan(finished: scan.finished, unknown: unknown)
    }

    /// SPEC §5: one decision report for the project's sweep; each finding also lands on its task's progress.
    @discardableResult
    public func recordWorktreeSweep(_ result: WorktreeSweepResult) throws -> Report {
        try db.writer.write { db in
            guard let project = try Project.fetchOne(db, key: result.projectId) else {
                throw BoardError.projectNotFound(result.projectId)
            }
            try Self.appendCleanupProgress(db, result.kept + result.teardownFailures)
            var lines = ["Clean up worktrees swept the worktrees of finished work in \(project.name). No branch was deleted."]
            if !result.removed.isEmpty {
                lines.append("Removed:\n" + result.removed.map { "- \($0)" }.joined(separator: "\n"))
            }
            lines.append(result.summary)
            return try ReportStore.insert(
                db, projectId: project.id, taskId: nil, sessionId: nil, kind: .decision,
                body: lines.joined(separator: "\n\n")
            )
        }
    }
}
