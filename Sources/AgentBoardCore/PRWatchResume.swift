import Foundation
import GRDB

/// The payload of a `pr_watch_resume` approval (SPEC §6 `resume_pr_watch`), with the parked reason as
/// it stood when the orchestrator asked.
public struct PRWatchResumeRequest: Codable, Sendable, Equatable {
    public var watchId: String
    public var number: Int
    public var title: String
    public var parkedReason: String?
    public var reason: String

    public init(watchId: String, number: Int, title: String, parkedReason: String?, reason: String) {
        self.watchId = watchId
        self.number = number
        self.title = title
        self.parkedReason = parkedReason
        self.reason = reason
    }

    public enum CodingKeys: String, CodingKey {
        case watchId = "watch_id"
        case number
        case title
        case parkedReason = "parked_reason"
        case reason
    }

    public func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    public static func decode(_ json: String?) throws -> PRWatchResumeRequest {
        guard let data = json?.data(using: .utf8) else { throw PRVerdictRejection("The approval carries no watch.") }
        return try JSONDecoder().decode(PRWatchResumeRequest.self, from: data)
    }
}

extension Board {
    /// The only path that creates a `pr_watch_resume` approval (SPEC §6 `resume_pr_watch`): nothing
    /// changes until a human grants it. Another project's watch is not found, the same answer as an
    /// unknown one, and a pending request for the same watch is returned as-is.
    @discardableResult
    public func requestWatchResume(projectId: String, watchId: String, reason: String, requestedBy: String) throws -> Approval {
        try db.writer.write { db in
            guard let watch = try PRWatch.filter(Column("id") == watchId && Column("project_id") == projectId).fetchOne(db)
            else { throw PRVerdictRejection("Pull request watch \(watchId) not found in this project.") }
            guard watch.state == .parked else {
                throw PRVerdictRejection("#\(watch.number) is \(watch.state.rawValue), not parked, so there is nothing to resume.")
            }
            guard let reason = PRWatchStore.nonBlank(reason)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw PRVerdictRejection("A resume request needs a reason: what was done about the parked reason.")
            }
            if let existing = try pendingWatchResume(db, projectId: projectId, watchId: watch.id) {
                return existing
            }
            let request = PRWatchResumeRequest(
                watchId: watch.id, number: watch.number, title: watch.title, parkedReason: watch.parkedReason, reason: reason
            )
            return try ApprovalStore.insert(
                db, projectId: projectId, kind: .prWatchResume, taskId: nil, epicId: nil, requestedBy: requestedBy,
                reason: "#\(watch.number) \(watch.title)\nParked: \(watch.parkedReason ?? "no reason recorded")\nReason: \(reason)",
                payload: try request.encoded()
            )
        }
    }

    /// Runs a granted `pr_watch_resume` through `PRWatchStore.resume`, as the Pull Requests page's Resume
    /// does (SPEC §13.4), and tells the orchestrator how it went as a `decision` report. A watch that has
    /// left `parked` since the request is reported, not thrown. Nil when nothing was resumed.
    @discardableResult
    public func applyWatchResume(_ approval: Approval, now: Int64 = .nowMillis) throws -> PRWatch? {
        let request = try PRWatchResumeRequest.decode(approval.payload)
        let resumed = try PRWatchStore(db).resume(watchId: request.watchId, now: now)
        let body: String
        if let resumed {
            body = "#\(request.number) resumed, now \(resumed.state.rawValue): \(request.reason)"
        } else {
            let state = try PRWatchStore(db).get(request.watchId)?.state.rawValue ?? "gone"
            body = "#\(request.number) was not resumed: it is no longer parked (it is \(state))."
        }
        try db.writer.write { db in
            _ = try ReportStore.insert(
                db, projectId: approval.projectId, taskId: nil, sessionId: nil, kind: .decision, body: body
            )
        }
        return resumed
    }

    private func pendingWatchResume(_ db: Database, projectId: String, watchId: String) throws -> Approval? {
        try Approval.fetchAll(
            db,
            sql: """
            SELECT * FROM approval WHERE project_id = ? AND kind = ? AND resolved_at IS NULL
            ORDER BY created_at, rowid
            """,
            arguments: [projectId, ApprovalKind.prWatchResume]
        ).first { (try? PRWatchResumeRequest.decode($0.payload).watchId) == watchId }
    }
}
