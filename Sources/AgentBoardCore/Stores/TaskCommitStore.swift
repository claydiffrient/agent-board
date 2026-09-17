import Foundation
import GRDB

/// Which task made which commit on a shared branch.
///
/// A worktree task is identified by its branch, `agentboard/<task-id>`. On a shared branch two
/// tasks' commits interleave on one ref, so the branch name cannot carry the mapping and this table
/// does instead. It is deliberately not in the commit object: a commit trailer would publish the
/// task's UUID into whatever repository the pull request lands in, permanently. The cost is that a
/// cherry-picked or rebased commit is a new object the ledger does not know, and that attribution
/// is no longer rebuildable from the repository alone.
public struct TaskCommitStore: Sendable {
    /// SQLite's default bound-parameter ceiling is 999; a long-lived shared branch can carry more
    /// commits than that.
    private static let chunk = 500

    let db: AppDatabase

    public init(_ db: AppDatabase) {
        self.db = db
    }

    public func record(taskId: String, sha: String) throws {
        try record([(taskId: taskId, sha: sha)])
    }

    public func record(_ rows: [(taskId: String, sha: String)]) throws {
        guard !rows.isEmpty else { return }
        try db.writer.write { db in
            for row in rows {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO task_commit (task_id, sha) VALUES (?, ?)",
                    arguments: [row.taskId, row.sha]
                )
            }
        }
    }

    /// Every ledgered sha among `shas`, mapped to the task that committed it. A sha with no row is
    /// absent from the result rather than mapped to nil.
    public func taskIds(forShas shas: [String]) throws -> [String: String] {
        guard !shas.isEmpty else { return [:] }
        return try db.reader.read { db in
            var found: [String: String] = [:]
            for batch in stride(from: 0, to: shas.count, by: Self.chunk).map({
                Array(shas[$0..<min($0 + Self.chunk, shas.count)])
            }) {
                let placeholders = databaseQuestionMarks(count: batch.count)
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT task_id, sha FROM task_commit WHERE sha IN (\(placeholders))",
                    arguments: StatementArguments(batch)
                )
                for row in rows { found[row["sha"]] = row["task_id"] }
            }
            return found
        }
    }

    public func shas(taskId: String) throws -> [String] {
        try db.reader.read { db in
            try String.fetchAll(
                db, sql: "SELECT sha FROM task_commit WHERE task_id = ? ORDER BY sha", arguments: [taskId]
            )
        }
    }
}
