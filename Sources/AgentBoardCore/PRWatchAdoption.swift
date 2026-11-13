import Foundation
import GRDB

/// The payload of a `pr_watch_adopt` approval (SPEC §6 `watch_pr`).
public struct PRWatchAdoptionRequest: Codable, Sendable, Equatable {
    public var number: Int
    public var reason: String

    public init(number: Int, reason: String) {
        self.number = number
        self.reason = reason
    }

    public func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    public static func decode(_ json: String?) throws -> PRWatchAdoptionRequest {
        guard let data = json?.data(using: .utf8) else { throw PRVerdictRejection("The approval carries no pull request.") }
        return try JSONDecoder().decode(PRWatchAdoptionRequest.self, from: data)
    }
}

extension Board {
    static let adoptionNeedsFollowThrough =
        "Adopting a pull request needs PR follow-through. Turn it on in the project's PR Follow-Through settings."

    /// The only path that creates a `pr_watch_adopt` approval (SPEC §6 `watch_pr`): nothing changes until a
    /// human grants it. What only GitHub can say, a fork or a closed pull request, is refused at the grant;
    /// a pending request for the same number is returned as-is.
    @discardableResult
    public func requestWatchAdoption(projectId: String, number: Int, reason: String, requestedBy: String) throws -> Approval {
        try db.writer.write { db in
            guard number > 0 else { throw PRVerdictRejection("A pull request number is a positive integer.") }
            guard let project = try Project.fetchOne(db, key: projectId) else {
                throw PRVerdictRejection("Project \(projectId) not found.")
            }
            guard project.settings.prFollowThrough.enabled else { throw PRVerdictRejection(Self.adoptionNeedsFollowThrough) }
            guard let reason = PRWatchStore.nonBlank(reason)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw PRVerdictRejection("A watch request needs a reason: why follow-through should take this pull request on.")
            }
            let watches = try PRWatch.filter(Column("project_id") == projectId && Column("number") == number).fetchAll(db)
            if let stopped = watches.first(where: { $0.state == .stopped }) {
                throw PRVerdictRejection(
                    "#\(number) is stopped. Ask with resume_pr_watch (watch_id \(stopped.id)) to watch it again."
                )
            }
            if let live = watches.first(where: { !$0.state.isTerminal && ($0.authored || $0.adopted) }) {
                throw PRVerdictRejection("#\(number) is already watched (\(live.state.rawValue)); there is nothing to adopt.")
            }
            if let existing = try pendingWatchAdoption(db, projectId: projectId, number: number) {
                return existing
            }
            return try ApprovalStore.insert(
                db, projectId: projectId, kind: .prWatchAdopt, taskId: nil, epicId: nil, requestedBy: requestedBy,
                reason: "#\(number)\nReason: \(reason)",
                payload: try PRWatchAdoptionRequest(number: number, reason: reason).encoded()
            )
        }
    }

    /// The `decision` report for a granted `watch_pr` whose adoption ran.
    public func reportWatchAdopted(_ request: PRWatchAdoptionRequest, watch: PRWatch, projectId: String) throws {
        try reportAdoption(
            projectId: projectId,
            body: "#\(request.number) \(watch.title) adopted into follow-through: \(request.reason)"
        )
    }

    /// The `decision` report for a granted `watch_pr` that was refused or failed, naming why.
    public func reportWatchNotAdopted(_ request: PRWatchAdoptionRequest, projectId: String, because cause: String) throws {
        try reportAdoption(projectId: projectId, body: "#\(request.number) was not adopted: \(cause)")
    }

    private func reportAdoption(projectId: String, body: String) throws {
        try db.writer.write { db in
            _ = try ReportStore.insert(db, projectId: projectId, taskId: nil, sessionId: nil, kind: .decision, body: body)
        }
    }

    private func pendingWatchAdoption(_ db: Database, projectId: String, number: Int) throws -> Approval? {
        try Approval.fetchAll(
            db,
            sql: """
            SELECT * FROM approval WHERE project_id = ? AND kind = ? AND resolved_at IS NULL
            ORDER BY created_at, rowid
            """,
            arguments: [projectId, ApprovalKind.prWatchAdopt]
        ).first { (try? PRWatchAdoptionRequest.decode($0.payload).number) == number }
    }
}
