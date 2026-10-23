import Foundation
import GRDB

/// A watch with the counts an orchestrator's `list_pr_watches` reports (SPEC §6, §13.6).
public struct PRWatchSummary: Sendable, Equatable {
    public var watch: PRWatch
    public var openItems: Int
    public var openDecisions: Int
    /// Items whose reply failed to post and was not abandoned (SPEC §13.2).
    public var failedReplies: Int

    public init(watch: PRWatch, openItems: Int, openDecisions: Int, failedReplies: Int) {
        self.watch = watch
        self.openItems = openItems
        self.openDecisions = openDecisions
        self.failedReplies = failedReplies
    }
}

public struct PRPollProblem: Sendable, Equatable {
    public var projectId: String
    public var detail: String
    public var since: Int64

    public init(projectId: String, detail: String, since: Int64) {
        self.projectId = projectId
        self.detail = detail
        self.since = since
    }
}

extension PRWatch {
    /// When a settling watch's feedback counts as settled (SPEC §13.1), absent a failed check that skips the wait.
    public func settleDeadline(settleMinutes: Int) -> Int64 {
        (lastFeedbackAt ?? updatedAt) + Int64(max(settleMinutes, 0)) * 60_000
    }
}

extension PRWatchStore {
    /// Every watch of `projectId` in `state`, or every one not merged or closed when `state` is nil, by number.
    public func summaries(projectId: String, state: PRWatchState? = nil) throws -> [PRWatchSummary] {
        var sql = """
        SELECT w.*,
          (SELECT COUNT(*) FROM pr_item i WHERE i.watch_id = w.id AND i.state = 'open') AS open_items,
          (SELECT COUNT(*) FROM pr_item i WHERE i.watch_id = w.id AND i.state = 'open'
             AND i.verdict = 'decision') AS open_decisions,
          (SELECT COUNT(*) FROM pr_item i WHERE i.watch_id = w.id AND i.reply_error IS NOT NULL
             AND i.reply_abandoned_at IS NULL) AS failed_replies
        FROM pr_watch w WHERE w.project_id = ?
        """
        var arguments: StatementArguments = [projectId]
        if let state {
            sql += " AND w.state = ?"
            arguments += [state]
        } else {
            sql += " AND w.state NOT IN ('merged', 'closed')"
        }
        sql += " ORDER BY w.repo_owner, w.repo_name, w.number"
        return try db.reader.read { db in
            try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
                PRWatchSummary(
                    watch: try PRWatch(row: row), openItems: row["open_items"], openDecisions: row["open_decisions"],
                    failedReplies: row["failed_replies"]
                )
            }
        }
    }

    /// Nil for another project's watch, the same answer as for an unknown id.
    public func watch(id: String, projectId: String) throws -> PRWatch? {
        try db.reader.read { db in
            try PRWatch.filter(Column("id") == id && Column("project_id") == projectId).fetchOne(db)
        }
    }

    /// More than one only when the project watches pull requests in more than one repository.
    public func watches(number: Int, projectId: String) throws -> [PRWatch] {
        try db.reader.read { db in
            try PRWatch.filter(Column("number") == number && Column("project_id") == projectId)
                .order(Column("repo_owner"), Column("repo_name")).fetchAll(db)
        }
    }

    public func pollProblem(projectId: String) throws -> PRPollProblem? {
        try db.reader.read { db in
            try Row.fetchOne(
                db, sql: "SELECT project_id, detail, since FROM pr_poll_problem WHERE project_id = ?",
                arguments: [projectId]
            ).map { PRPollProblem(projectId: $0["project_id"], detail: $0["detail"], since: $0["since"]) }
        }
    }
}
