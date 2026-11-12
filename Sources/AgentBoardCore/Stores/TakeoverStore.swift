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
                issueNodeId: candidate.issueNodeId, issueURL: candidate.issueURL, title: candidate.title,
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

    @discardableResult
    public func startWorking(_ id: String, taskId: String, now: Int64 = .nowMillis) throws -> Takeover? {
        try move(id, to: .working, now: now) { $0.taskId = taskId }
    }

    @discardableResult
    public func watch(_ id: String, watchId: String, now: Int64 = .nowMillis) throws -> Takeover? {
        try move(id, to: .watched, now: now) { $0.watchId = watchId }
    }

    @discardableResult
    public func finish(_ id: String, now: Int64 = .nowMillis) throws -> Takeover? {
        try move(id, to: .done, now: now)
    }

    @discardableResult
    public func release(_ id: String, now: Int64 = .nowMillis) throws -> Takeover? {
        try move(id, to: .released, now: now)
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
            change(&row)
            row.updatedAt = now
            try row.update(db)
            return row
        }
    }
}
