import Foundation
import GRDB

public struct ApprovalStore: Sendable {
    let db: AppDatabase

    public init(_ db: AppDatabase) {
        self.db = db
    }

    @discardableResult
    public func create(
        projectId: String, kind: ApprovalKind, taskId: String?, epicId: String?,
        requestedBy: String, reason: String?, payload: String? = nil
    ) throws -> Approval {
        try db.writer.write { db in
            try Self.insert(
                db, projectId: projectId, kind: kind, taskId: taskId, epicId: epicId,
                requestedBy: requestedBy, reason: reason, payload: payload
            )
        }
    }

    static func insert(
        _ db: Database, projectId: String, kind: ApprovalKind, taskId: String?, epicId: String?,
        requestedBy: String, reason: String?, payload: String? = nil
    ) throws -> Approval {
        let approval = Approval(
            id: Approval.newId(),
            projectId: projectId,
            kind: kind,
            taskId: taskId,
            epicId: epicId,
            requestedBy: requestedBy,
            reason: reason,
            payload: payload,
            createdAt: .nowMillis
        )
        try approval.insert(db)
        return approval
    }

    public func get(_ id: String) throws -> Approval? {
        try db.reader.read { db in try Approval.fetchOne(db, key: id) }
    }

    public func pending(projectId: String) throws -> [Approval] {
        try db.reader.read { db in try Self.pending(db, projectId: projectId) }
    }

    static func pending(_ db: Database, projectId: String) throws -> [Approval] {
        try Approval.fetchAll(
            db,
            sql: "SELECT * FROM approval WHERE project_id = ? AND resolved_at IS NULL ORDER BY created_at, rowid",
            arguments: [projectId]
        )
    }

    public func pendingSpawn(taskId: String) throws -> Approval? {
        try db.reader.read { db in try Self.pendingSpawn(db, taskId: taskId) }
    }

    static func pendingSpawn(_ db: Database, taskId: String) throws -> Approval? {
        try Approval.fetchOne(
            db,
            sql: """
            SELECT * FROM approval
            WHERE task_id = ? AND kind = 'spawn' AND resolved_at IS NULL
            ORDER BY created_at, rowid LIMIT 1
            """,
            arguments: [taskId]
        )
    }

    public static func pendingIntegration(_ db: Database, epicId: String) throws -> Approval? {
        try Approval.fetchOne(
            db,
            sql: """
            SELECT * FROM approval
            WHERE epic_id = ? AND kind = 'integration' AND resolved_at IS NULL
            ORDER BY created_at, rowid LIMIT 1
            """,
            arguments: [epicId]
        )
    }

    /// A pending `push` or `pull_request` approval already aimed at this branch. Matching on the
    /// decoded payload rather than a column keeps the dedup honest without widening the schema.
    public static func pendingPublish(
        _ db: Database, projectId: String, kind: ApprovalKind, branch: String
    ) throws -> Approval? {
        try Approval.fetchAll(
            db,
            sql: """
            SELECT * FROM approval
            WHERE project_id = ? AND kind = ? AND resolved_at IS NULL
            ORDER BY created_at, rowid
            """,
            arguments: [projectId, kind.rawValue]
        ).first { (try? $0.publishRequest().branch) == branch }
    }

    @discardableResult
    public func resolve(_ id: String, _ resolution: ApprovalResolution) throws -> Approval {
        try db.writer.write { db in try Self.resolve(db, id, resolution) }
    }

    static func resolve(_ db: Database, _ id: String, _ resolution: ApprovalResolution) throws -> Approval {
        guard var approval = try Approval.fetchOne(db, key: id) else {
            throw BoardError.approvalNotFound(id)
        }
        guard approval.isPending else {
            throw BoardError.approvalAlreadyResolved(id)
        }
        approval.resolvedAt = .nowMillis
        approval.resolution = resolution
        try approval.update(db)
        return approval
    }

    /// The URL an approved `open_pull_request` produced. It lives on the approval rather than being
    /// read back from the card's progress rows, which a worker's `update_status` also writes (§5).
    static func recordPublishedURL(_ db: Database, approvalId: String, url: String) throws {
        try db.execute(sql: "UPDATE approval SET published_url = ? WHERE id = ?", arguments: [url, approvalId])
    }

    /// The newest pull request an approved `open_pull_request` naming this task opened.
    static func publishedPullRequest(_ db: Database, taskId: String) throws -> PullRequestReference? {
        try String.fetchOne(
            db,
            sql: """
            SELECT published_url FROM approval
            WHERE task_id = ? AND kind = 'pull_request' AND published_url IS NOT NULL
            ORDER BY resolved_at DESC, created_at DESC, rowid DESC LIMIT 1
            """,
            arguments: [taskId]
        ).flatMap(PullRequestReference.init(in:))
    }

    /// The newest pull request an approved `open_pull_request(epic_id:)` opened from the epic branch.
    /// A task-branch pull request inside the epic names its task and is not the epic's.
    static func publishedEpicPullRequest(_ db: Database, epicId: String) throws -> PullRequestReference? {
        try String.fetchOne(
            db,
            sql: """
            SELECT published_url FROM approval
            WHERE epic_id = ? AND task_id IS NULL AND kind = 'pull_request' AND published_url IS NOT NULL
            ORDER BY resolved_at DESC, created_at DESC, rowid DESC LIMIT 1
            """,
            arguments: [epicId]
        ).flatMap(PullRequestReference.init(in:))
    }

    public func publishedEpicPullRequest(epicId: String) throws -> PullRequestReference? {
        try db.reader.read { db in try Self.publishedEpicPullRequest(db, epicId: epicId) }
    }

    /// Each PR-open epic's pull request, keyed by epic id, for the lane headers.
    public func observeEpicPullRequests(projectId: String) -> ValueObservation<ValueReducers.Fetch<[String: PullRequestReference]>> {
        ValueObservation.tracking { db in
            let ids = try String.fetchAll(
                db,
                sql: "SELECT id FROM epic WHERE project_id = ? AND state = ?",
                arguments: [projectId, EpicState.pullRequestOpen]
            )
            var byEpic: [String: PullRequestReference] = [:]
            for id in ids {
                byEpic[id] = try Self.publishedEpicPullRequest(db, epicId: id)
            }
            return byEpic
        }
    }

    /// Fills `published_url` for pull requests opened before it existed, from the first progress row
    /// the publish wrote after the approval resolved. That row leads with the summary
    /// `WorkerSupervisor.publish` gives; a worker's status rows lead with its state word instead.
    static func backfillPublishedURLs(_ db: Database) throws {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT id, task_id, COALESCE(resolved_at, created_at) AS since FROM approval
            WHERE kind = 'pull_request' AND task_id IS NOT NULL AND published_url IS NULL
            """
        )
        for row in rows {
            let id: String = row["id"]
            let taskId: String = row["task_id"]
            let since: Int64 = row["since"]
            let text = try String.fetchOne(
                db,
                sql: """
                SELECT text FROM progress
                WHERE task_id = ? AND kind = 'status' AND session_id IS NULL AND at >= ?
                  AND (text LIKE 'Pull request opened from %' OR text LIKE 'Pull request already open from %')
                ORDER BY at, id LIMIT 1
                """,
                arguments: [taskId, since]
            )
            guard let pr = text.flatMap(PullRequestReference.init(in:)) else { continue }
            try recordPublishedURL(db, approvalId: id, url: pr.url)
        }
    }

    public func observePending(projectId: String) -> ValueObservation<ValueReducers.Fetch<[Approval]>> {
        ValueObservation.tracking { db in
            try Self.pending(db, projectId: projectId)
        }
    }
}
