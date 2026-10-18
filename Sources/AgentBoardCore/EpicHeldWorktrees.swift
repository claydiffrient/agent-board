import Foundation
import GRDB

/// A worktree still on disk that belongs to an epic: a member task's, its integration task's, or
/// the epic's own integration checkout (SPEC §5.2, "Worktrees a closed epic leaves behind").
public struct HeldWorktree: Sendable, Equatable, Identifiable {
    public var path: String
    /// Nil for the integration checkout when no session ever recorded it.
    public var taskId: String?
    public var taskTitle: String?
    public var isIntegration: Bool

    public init(path: String, taskId: String?, taskTitle: String?, isIntegration: Bool) {
        self.path = path
        self.taskId = taskId
        self.taskTitle = taskTitle
        self.isIntegration = isIntegration
    }

    public var id: String { path }

    public var line: String {
        let owner = switch (taskId, isIntegration) {
        case (let taskId?, true): "integration task \(taskId)"
        case (nil, _): "the epic's integration checkout"
        case (let taskId?, false): "task \(taskId)" + (taskTitle.map { " (\($0))" } ?? "")
        }
        return "- \(path) — \(owner)"
    }

    public static func epicWorktreeName(epicId: String) -> String { "epic-\(epicId)" }

    /// The paragraph a close or done report carries, or nil when nothing is left on disk.
    public static func paragraph(_ held: [HeldWorktree]) -> String? {
        guard !held.isEmpty else { return nil }
        return "\(held.count) worktree(s) for this epic are still on disk. Nothing will push from them "
            + "again; a human can remove them, running the project's teardown hook, with Remove worktrees "
            + "on the epic's lane:\n" + held.map(\.line).joined(separator: "\n")
    }
}

extension Board {
    public func heldWorktrees(epicId: String) throws -> [HeldWorktree] {
        try db.reader.read { db in try Self.heldWorktrees(db, epicId: epicId) }
    }

    static func heldWorktrees(_ db: Database, epicId: String) throws -> [HeldWorktree] {
        guard let epic = try Epic.fetchOne(db, key: epicId),
              let project = try Project.fetchOne(db, key: epic.projectId)
        else { throw BoardError.epicNotFound(epicId) }
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT s.worktree_path, t.id, t.title, t.origin
                FROM agent_session s JOIN task t ON t.id = s.task_id
                WHERE t.epic_id = ? AND s.worktree_path IS NOT NULL
                ORDER BY s.started_at, s.rowid
                """,
            arguments: [epicId]
        )
        var candidates = rows.map { row in
            HeldWorktree(
                path: row[0], taskId: row[1], taskTitle: row[2],
                isIntegration: (row[3] as TaskOrigin?) == .integration
            )
        }
        let epicCheckout = URL(fileURLWithPath: project.worktreeRoot)
            .appendingPathComponent(HeldWorktree.epicWorktreeName(epicId: epicId)).path
        candidates.append(HeldWorktree(path: epicCheckout, taskId: nil, taskTitle: nil, isIntegration: true))

        var seen: Set<String> = [resolved(project.repoPath)]
        return candidates.filter { candidate in
            FileManager.default.fileExists(atPath: candidate.path) && seen.insert(resolved(candidate.path)).inserted
        }
    }

    private static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// The confirmation behind Remove worktrees on a done or abandoned epic's lane.
public struct EpicWorktreeRemoval: Sendable, Equatable {
    public var epicId: String
    public var epicTitle: String
    public var held: [HeldWorktree]

    public init(epicId: String, epicTitle: String, held: [HeldWorktree]) {
        self.epicId = epicId
        self.epicTitle = epicTitle
        self.held = held
    }

    public var title: String { "Remove the worktrees \"\(epicTitle)\" left behind?" }

    public var message: String {
        guard !held.isEmpty else { return "No worktree for this epic or its integration task is on disk." }
        return "Runs the project's teardown hook in each, then removes it. A worktree with uncommitted "
            + "changes, or one a running session holds, is kept and named in the report. No branch is "
            + "deleted.\n\n" + held.map(\.line).joined(separator: "\n")
    }
}
