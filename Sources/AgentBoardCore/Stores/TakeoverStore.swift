import Foundation
import GRDB

/// The `takeover` rows (SPEC §13.8). Every transition re-reads the row inside its write and does nothing
/// unless `TakeoverState.canMove(to:)` allows the move, so two writers racing on one row cannot regress it.
public struct TakeoverStore: Sendable {
    let db: AppDatabase

    public init(_ db: AppDatabase) {
        self.db = db
    }

    /// Inserts `candidate` as `found`, or returns nil when the project already recorded its node id,
    /// either as an item or as the issue a recorded pull request closes.
    @discardableResult
    public func record(projectId: String, _ candidate: TakeoverCandidate, now: Int64 = .nowMillis) throws -> Takeover? {
        try db.writer.write { db in
            let known = try Bool.fetchOne(
                db,
                sql: """
                SELECT EXISTS (SELECT 1 FROM takeover WHERE project_id = ? AND (github_node_id = ? OR issue_node_id = ?))
                """,
                arguments: [projectId, candidate.githubNodeId, candidate.githubNodeId]
            ) ?? false
            guard !known else { return nil }
            let row = Takeover(
                id: Takeover.newId(), projectId: projectId, githubNodeId: candidate.githubNodeId,
                kind: candidate.kind, number: candidate.number, url: candidate.url,
                issueNodeId: candidate.issueNodeId, issueURL: candidate.issueURL, viaIssue: candidate.viaIssue,
                title: candidate.title,
                author: candidate.author, isCrossRepository: candidate.isCrossRepository, state: .found,
                taskId: nil, watchId: nil, failure: nil, createdAt: now, updatedAt: now
            )
            try row.insert(db)
            return row
        }
    }

    /// Every node id the project has recorded, issues a recorded pull request closes included.
    public func recordedNodeIds(projectId: String) throws -> Set<String> {
        try db.reader.read { db in
            Set(try String.fetchAll(
                db,
                sql: """
                SELECT github_node_id FROM takeover WHERE project_id = ?
                UNION SELECT issue_node_id FROM takeover WHERE project_id = ? AND issue_node_id IS NOT NULL
                """,
                arguments: [projectId, projectId]
            ))
        }
    }

    public func get(_ id: String) throws -> Takeover? {
        try db.reader.read { try Takeover.fetchOne($0, key: id) }
    }

    /// The project's rows not yet done, released or failed.
    public func live(projectId: String) throws -> [Takeover] {
        try db.reader.read { db in
            try Takeover.fetchAll(
                db,
                sql: """
                SELECT * FROM takeover WHERE project_id = ? AND state NOT IN ('done', 'released', 'failed')
                ORDER BY number
                """,
                arguments: [projectId]
            )
        }
    }

    @discardableResult
    public func acknowledge(_ id: String, now: Int64 = .nowMillis) throws -> Takeover? {
        try move(id, to: .acknowledged, now: now)
    }

    /// Sets `failure` on a live row without moving it, for a step that failed after its state was recorded or
    /// cannot run yet; nil clears it.
    @discardableResult
    public func noteProblem(_ id: String, detail: String?, now: Int64 = .nowMillis) throws -> Takeover? {
        try db.writer.write { db in
            guard var row = try Takeover.fetchOne(db, key: id), !row.state.isTerminal else { return nil }
            row.failure = detail
            row.updatedAt = now
            try row.update(db)
            return row
        }
    }

    /// Writes the issue's `code` task in `backlog` and records it on the row, in one write (SPEC §13.8).
    /// A row that already has a task returns that task, so an issue never gets two; nil unless the row is
    /// a live issue still waiting to start.
    public func createTask(_ id: String, issue: TakeoverIssue, now: Int64 = .nowMillis) throws -> Task? {
        try db.writer.write { db in
            guard var row = try Takeover.fetchOne(db, key: id), row.kind == .issue,
                  row.state == .found || row.state == .acknowledged
            else { return nil }
            if let existing = try row.taskId.flatMap({ try Task.fetchOne(db, key: $0) }) { return existing }
            let task = try TaskStore.insert(
                db, projectId: row.projectId, title: issue.taskTitle, body: issue.taskBody, acceptance: nil,
                priority: nil, column: .backlog, origin: .takeover, epicId: nil, type: .code
            )
            row.taskId = task.id
            row.failure = nil
            row.updatedAt = now
            try row.update(db)
            return task
        }
    }

    /// Moves the row to `working` and its task from `backlog` to `ready`, where a spawn can take it.
    @discardableResult
    public func startWorking(_ id: String, taskId: String, now: Int64 = .nowMillis) throws -> Takeover? {
        try db.writer.write { db in
            guard var row = try Takeover.fetchOne(db, key: id), row.state.canMove(to: .working) else { return nil }
            row.state = .working
            row.taskId = taskId
            row.failure = nil
            row.updatedAt = now
            try row.update(db)
            if try Task.fetchOne(db, key: taskId)?.column == .backlog {
                try TaskStore.move(db, taskId, to: .ready, before: nil)
            }
            return row
        }
    }

    /// The issue row whose task this is, for the closing line its pull request carries.
    public func issue(taskId: String) throws -> Takeover? {
        try db.reader.read { db in
            try Takeover.filter(Column("task_id") == taskId && Column("kind") == TakeoverKind.issue).fetchOne(db)
        }
    }

    /// A pull request body for `taskId`'s branch. A taken-over issue's task gains a closing line unless
    /// the body already closes that issue (SPEC §13.8); any other task's body is returned unchanged.
    /// `pullRequestRepository` is the `owner/name` the pull request opens on, nil when unknown.
    public func closingBody(_ body: String, taskId: String?, pullRequestRepository: String? = nil) throws -> String {
        guard let taskId, let issue = try issue(taskId: taskId),
              let repository = IssueClosingReference.repository(of: issue.url)
        else { return body }
        let target = pullRequestRepository ?? repository
        guard !IssueClosingReference.closes(
            body: body, number: issue.number, issueRepository: repository, pullRequestRepository: target
        ) else { return body }
        let line = IssueClosingReference.line(
            number: issue.number, issueRepository: repository, pullRequestRepository: target
        )
        return body.isEmpty ? line : body + "\n\n" + line
    }

    /// SPEC §13.8: a pull request follow-through watches whose body closes a live issue row moves that
    /// row to `watched` on this watch.
    @discardableResult
    public func watchClosingPullRequest(
        projectId: String, watchId: String, repository: String, body: String, now: Int64 = .nowMillis
    ) throws -> [Takeover] {
        try db.writer.write { db in
            let rows = try Takeover.fetchAll(
                db,
                sql: """
                SELECT * FROM takeover WHERE project_id = ? AND kind = 'issue' AND watch_id IS NULL
                  AND state IN ('acknowledged', 'working')
                """,
                arguments: [projectId]
            )
            return try rows.compactMap { row -> Takeover? in
                guard let issueRepository = IssueClosingReference.repository(of: row.url),
                      IssueClosingReference.closes(
                          body: body, number: row.number, issueRepository: issueRepository,
                          pullRequestRepository: repository
                      )
                else { return nil }
                var watched = row
                watched.state = .watched
                watched.watchId = watchId
                watched.failure = nil
                watched.updatedAt = now
                try watched.update(db)
                return watched
            }
        }
    }

    /// The rows watching `watchId` are done once it merges (SPEC §13.8).
    static func finishWatching(_ db: Database, watchId: String, now: Int64) throws {
        try db.execute(
            sql: """
            UPDATE takeover SET state = 'done', failure = NULL, updated_at = ? WHERE watch_id = ? AND state = 'watched'
            """,
            arguments: [now, watchId]
        )
    }

    @discardableResult
    public func watch(_ id: String, watchId: String, now: Int64 = .nowMillis) throws -> Takeover? {
        try move(id, to: .watched, now: now) { $0.watchId = watchId }
    }

    @discardableResult
    public func finish(_ id: String, now: Int64 = .nowMillis) throws -> Takeover? {
        try move(id, to: .done, now: now)
    }

    /// Releases the row. An issue's task that has not started is closed with a reason in the same
    /// write, the way `close_task` closes one, and the orchestrator is told; a started one is left
    /// to finish. A pull request's watch stops being adopted in the same write, so a round in flight
    /// cannot push; the human's own authored pull request also drops the takeover and keeps its
    /// follow-through (SPEC §13.8).
    @discardableResult
    public func release(_ id: String, now: Int64 = .nowMillis) throws -> Takeover? {
        try db.writer.write { db in
            guard var row = try Takeover.fetchOne(db, key: id), row.state.canMove(to: .released) else { return nil }
            row.state = .released
            row.failure = nil
            row.updatedAt = now
            try row.update(db)
            try db.execute(
                sql: """
                UPDATE pr_watch SET adopted = 0, updated_at = ?,
                  takeover_id = CASE WHEN authored = 1 OR state IN ('stopped', 'merged', 'closed')
                    THEN NULL ELSE takeover_id END
                WHERE takeover_id = ?
                """,
                arguments: [now, row.id]
            )
            guard row.kind == .issue, let task = try row.taskId.flatMap({ try Task.fetchOne(db, key: $0) }),
                  [.proposed, .backlog, .ready].contains(task.column)
            else { return row }
            let reason = "Issue #\(row.number) was released from takeover: it lost a trigger label or is no "
                + "longer assigned to the human."
            guard try Board.closeRefusal(db, task: task, reason: reason) == nil else { return row }
            try Board.retire(db, task: task, reason: reason, by: "takeover")
            _ = try ReportStore.insert(
                db, projectId: row.projectId, taskId: task.id, sessionId: nil, kind: .decision,
                body: "Takeover closed task \(task.id) (\(task.title)) before it started. \(reason) \(row.url)"
            )
            return row
        }
    }

    @discardableResult
    public func fail(_ id: String, reason: String, now: Int64 = .nowMillis) throws -> Takeover? {
        try move(id, to: .failed, now: now) { $0.failure = reason }
    }

    /// The Pull Requests page's Taken over group: newest change first.
    public func page(projectId: String? = nil) throws -> [Takeover] {
        try db.reader.read { try Self.page($0, projectId: projectId) }
    }

    public func observePage(projectId: String? = nil) -> ValueObservation<ValueReducers.Fetch<[Takeover]>> {
        ValueObservation.tracking { try Self.page($0, projectId: projectId) }
    }

    static func page(_ db: Database, projectId: String?) throws -> [Takeover] {
        if let projectId {
            return try Takeover.fetchAll(
                db, sql: "SELECT * FROM takeover WHERE project_id = ? ORDER BY updated_at DESC, number",
                arguments: [projectId]
            )
        }
        return try Takeover.fetchAll(db, sql: "SELECT * FROM takeover ORDER BY updated_at DESC, number")
    }

    private func move(
        _ id: String, to next: TakeoverState, now: Int64, _ change: (inout Takeover) -> Void = { _ in }
    ) throws -> Takeover? {
        try db.writer.write { db in
            guard var row = try Takeover.fetchOne(db, key: id), row.state.canMove(to: next) else { return nil }
            row.state = next
            if next != .failed { row.failure = nil }
            change(&row)
            row.updatedAt = now
            try row.update(db)
            return row
        }
    }
}
