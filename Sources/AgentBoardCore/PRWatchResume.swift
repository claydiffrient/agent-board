import Foundation
import GRDB

/// The payload of a `pr_watch_resume` approval (SPEC §6 `resume_pr_watch`), with the parked reason as
/// it stood when the orchestrator asked. `stopped` marks a request to watch a stopped PR again, whose
/// parked reason is the one it had when the human stopped it.
public struct PRWatchResumeRequest: Codable, Sendable, Equatable {
    public var watchId: String
    public var number: Int
    public var title: String
    public var parkedReason: String?
    public var reason: String
    public var stopped: Bool

    public init(
        watchId: String, number: Int, title: String, parkedReason: String?, reason: String, stopped: Bool = false
    ) {
        self.watchId = watchId
        self.number = number
        self.title = title
        self.parkedReason = parkedReason
        self.reason = reason
        self.stopped = stopped
    }

    public enum CodingKeys: String, CodingKey {
        case watchId = "watch_id"
        case number
        case title
        case parkedReason = "parked_reason"
        case reason
        case stopped
    }

    /// A request filed before `stopped` existed was for a parked watch.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        watchId = try container.decode(String.self, forKey: .watchId)
        number = try container.decode(Int.self, forKey: .number)
        title = try container.decode(String.self, forKey: .title)
        parkedReason = try container.decodeIfPresent(String.self, forKey: .parkedReason)
        reason = try container.decode(String.self, forKey: .reason)
        stopped = try container.decodeIfPresent(Bool.self, forKey: .stopped) ?? false
    }

    /// The approval's line for why follow-through let go of the PR.
    public var parkedLine: String {
        let parked = parkedReason ?? "no reason recorded"
        return stopped ? "Stopped watching; it had parked because: \(parked)" : "Parked: \(parked)"
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
    /// The only path that creates a `pr_watch_resume` approval (SPEC §6 `resume_pr_watch`), for a parked or
    /// stopped watch: nothing changes until a human grants it. Another project's watch is not found, the
    /// same answer as an unknown one, and a pending request for the same watch is returned as-is.
    @discardableResult
    public func requestWatchResume(projectId: String, watchId: String, reason: String, requestedBy: String) throws -> Approval {
        try db.writer.write { db in
            guard let watch = try PRWatch.filter(Column("id") == watchId && Column("project_id") == projectId).fetchOne(db)
            else { throw PRVerdictRejection("Pull request watch \(watchId) not found in this project.") }
            guard watch.state.isResumable else {
                throw PRVerdictRejection(
                    "#\(watch.number) is \(watch.state.rawValue), not parked or stopped, so there is nothing to resume."
                )
            }
            guard let reason = PRWatchStore.nonBlank(reason)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw PRVerdictRejection(watch.state == .stopped
                    ? "A request to watch a stopped pull request again needs a reason: why follow-through should take it back."
                    : "A resume request needs a reason: what was done about the parked reason.")
            }
            if let existing = try pendingWatchResume(db, projectId: projectId, watchId: watch.id) {
                return existing
            }
            let request = PRWatchResumeRequest(
                watchId: watch.id, number: watch.number, title: watch.title, parkedReason: watch.parkedReason,
                reason: reason, stopped: watch.state == .stopped
            )
            return try ApprovalStore.insert(
                db, projectId: projectId, kind: .prWatchResume, taskId: nil, epicId: nil, requestedBy: requestedBy,
                reason: "#\(watch.number) \(watch.title)\n\(request.parkedLine)\nReason: \(reason)",
                payload: try request.encoded()
            )
        }
    }

    /// Runs a granted `pr_watch_resume` through `PRWatchStore.resume`, as the Pull Requests page's Resume
    /// and Watch again do (SPEC §13.4), and tells the orchestrator how it went as a `decision` report. A
    /// watch that is no longer parked or stopped is reported, not thrown; any other failure is reported and
    /// rethrown. Nil when nothing was resumed.
    @discardableResult
    public func applyWatchResume(_ approval: Approval, now: Int64 = .nowMillis) throws -> PRWatch? {
        let request = try PRWatchResumeRequest.decode(approval.payload)
        do {
            return try db.writer.write { db in
                let resumed = try PRWatchStore.resume(db, watchId: request.watchId, now: now)
                let body: String
                if let resumed {
                    let verb = request.stopped ? "watched again" : "resumed"
                    body = "#\(request.number) \(verb), now \(resumed.state.rawValue): \(request.reason)"
                } else {
                    let state = try PRWatch.fetchOne(db, key: request.watchId)?.state.rawValue ?? "gone"
                    body = "#\(request.number) was not resumed: it is no longer \(request.stopped ? "stopped" : "parked") (it is \(state))."
                }
                _ = try ReportStore.insert(
                    db, projectId: approval.projectId, taskId: nil, sessionId: nil, kind: .decision, body: body
                )
                return resumed
            }
        } catch {
            try reportWatchNotResumed(request, projectId: approval.projectId, because: error.localizedDescription)
            throw error
        }
    }

    /// The `decision` report for a granted resume that failed, naming why.
    public func reportWatchNotResumed(_ request: PRWatchResumeRequest, projectId: String, because cause: String) throws {
        try db.writer.write { db in
            _ = try ReportStore.insert(
                db, projectId: projectId, taskId: nil, sessionId: nil, kind: .decision,
                body: "#\(request.number) was not resumed: \(cause)"
            )
        }
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
