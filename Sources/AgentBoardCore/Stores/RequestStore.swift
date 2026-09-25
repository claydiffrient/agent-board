import Foundation
import GRDB

public enum RequestError: Error, Equatable, Sendable {
    case unknownProject(String)
    case unknownRequest(Int64)
    /// The request exists but is addressed to another project; reported the same as an unknown id
    /// by the tools, so a project cannot probe another's requests.
    case notAddressedTo(projectId: String, requestId: Int64)
    case closed(Int64, RequestState)
    case notAReplyState(RequestState)
    case foreignEpic(String)
    case emptyBody
}

/// One request as the Coordinator reads its ledger.
public struct RequestLedgerEntry: Sendable, Equatable {
    public var request: CoordinatorRequest
    public var projectName: String
    public var history: [RequestEvent]
    public var epicIds: [String]
}

/// The Coordinator's request ledger and the report each step queues (SPEC §9.4). Every write here is
/// one transaction with its report, so a request that exists is always in its target's queue, and a
/// reply that exists is always in the Coordinator's.
public struct RequestStore: Sendable {
    let db: AppDatabase

    public init(_ db: AppDatabase) {
        self.db = db
    }

    /// Closed requests older than this, counted from when they closed, are deleted by `deleteExpired`.
    public static let retentionMillis: Int64 = 7 * ArchiveSweep.millisPerDay

    @discardableResult
    public func send(toProjectId: String, body: String, planNoteId: String?) throws -> (request: CoordinatorRequest, report: Report) {
        let text = try Self.trimmed(body)
        return try db.writer.write { db in
            guard try Project.exists(db, key: toProjectId) else { throw RequestError.unknownProject(toProjectId) }
            let now = Int64.nowMillis
            var request = CoordinatorRequest(projectId: toProjectId, body: text, planNoteId: planNoteId, createdAt: now)
            try request.insert(db)
            guard let id = request.id else { throw RequestError.unknownRequest(0) }
            let report = try ReportStore.insert(
                db, projectId: toProjectId, taskId: nil, sessionId: nil, kind: .request,
                body: CoordinatorRequest.deliveredBody(requestId: id, planNoteId: planNoteId, text: text)
            )
            var event = RequestEvent(requestId: id, state: .sent, author: .coordinator, body: text, reportId: report.id, createdAt: now)
            try event.insert(db)
            return (request, report)
        }
    }

    /// An orchestrator's answer. Only the project a request is addressed to may reply, only while it
    /// is open, and only with `RequestState.replies`; `epicIds` must be that project's epics.
    @discardableResult
    public func reply(
        requestId: Int64, fromProjectId: String, state: RequestState, body: String, epicIds: [String] = []
    ) throws -> (request: CoordinatorRequest, report: Report) {
        guard RequestState.replies.contains(state) else { throw RequestError.notAReplyState(state) }
        let text = try Self.trimmed(body)
        return try db.writer.write { db in
            guard var request = try CoordinatorRequest.fetchOne(db, key: requestId) else {
                throw RequestError.unknownRequest(requestId)
            }
            guard request.projectId == fromProjectId else {
                throw RequestError.notAddressedTo(projectId: fromProjectId, requestId: requestId)
            }
            guard !request.state.isClosed else { throw RequestError.closed(requestId, request.state) }
            guard let project = try Project.fetchOne(db, key: fromProjectId) else {
                throw RequestError.unknownProject(fromProjectId)
            }
            for epicId in epicIds {
                guard let epic = try Epic.fetchOne(db, key: epicId), epic.projectId == fromProjectId else {
                    throw RequestError.foreignEpic(epicId)
                }
            }
            let now = Int64.nowMillis
            request.state = state
            request.closedAt = state.isClosed ? now : nil
            try request.update(db)
            for epicId in epicIds {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO request_epic (request_id, epic_id) VALUES (?, ?)",
                    arguments: [requestId, epicId]
                )
            }
            var report = Report(
                projectId: nil, taskId: nil, sessionId: nil, kind: .reply,
                body: CoordinatorRequest.deliveredReply(
                    requestId: requestId, fromProjectName: project.name, fromProjectId: project.id, state: state,
                    epicIds: epicIds, text: text
                ),
                createdAt: now
            )
            try report.insert(db)
            var event = RequestEvent(
                requestId: requestId, state: state, author: .orchestrator, body: text, reportId: report.id, createdAt: now
            )
            try event.insert(db)
            return (request, report)
        }
    }

    /// Closes an open request and tells its target, whose queue gets a `request` report saying so.
    @discardableResult
    public func withdraw(requestId: Int64, reason: String?) throws -> (request: CoordinatorRequest, report: Report) {
        let reasonText = (reason?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        return try db.writer.write { db in
            guard var request = try CoordinatorRequest.fetchOne(db, key: requestId) else {
                throw RequestError.unknownRequest(requestId)
            }
            guard !request.state.isClosed else { throw RequestError.closed(requestId, request.state) }
            let now = Int64.nowMillis
            request.state = .withdrawn
            request.closedAt = now
            try request.update(db)
            let report = try ReportStore.insert(
                db, projectId: request.projectId, taskId: nil, sessionId: nil, kind: .request,
                body: CoordinatorRequest.withdrawnBody(requestId: requestId, reason: reasonText)
            )
            var event = RequestEvent(
                requestId: requestId, state: .withdrawn, author: .coordinator, body: reasonText ?? "",
                reportId: report.id, createdAt: now
            )
            try event.insert(db)
            return (request, report)
        }
    }

    public func get(_ id: Int64) throws -> CoordinatorRequest? {
        try db.reader.read { db in try CoordinatorRequest.fetchOne(db, key: id) }
    }

    /// The request a report was queued for — its delivery, a reply, or its withdrawal.
    public func request(forReportId reportId: Int64) throws -> Int64? {
        try db.reader.read { db in
            try Int64.fetchOne(db, sql: "SELECT request_id FROM request_event WHERE report_id = ?", arguments: [reportId])
        }
    }

    /// Newest first. Closed requests stay listed until the sweep deletes them.
    public func ledger(includeClosed: Bool = true) throws -> [RequestLedgerEntry] {
        try db.reader.read { db in
            let requests = try CoordinatorRequest.fetchAll(
                db,
                sql: "SELECT * FROM coordinator_request\(includeClosed ? "" : " WHERE closed_at IS NULL") ORDER BY created_at DESC, id DESC"
            )
            return try requests.map { request in
                let id = request.id ?? 0
                return RequestLedgerEntry(
                    request: request,
                    projectName: try String.fetchOne(db, sql: "SELECT name FROM project WHERE id = ?", arguments: [request.projectId]) ?? "",
                    history: try RequestEvent.fetchAll(
                        db, sql: "SELECT * FROM request_event WHERE request_id = ? ORDER BY created_at, id", arguments: [id]
                    ),
                    epicIds: try String.fetchAll(
                        db, sql: "SELECT epic_id FROM request_epic WHERE request_id = ? ORDER BY rowid", arguments: [id]
                    )
                )
            }
        }
    }

    /// The same sweep as messages (SPEC §9.3): deletes requests closed more than `retentionMillis`
    /// ago, with their history, epic links and every report they queued. Open requests are kept.
    @discardableResult
    public func deleteExpired(now: Int64 = .nowMillis) throws -> Int {
        let cutoff = now - Self.retentionMillis
        return try db.writer.write { db in
            let ids = try Int64.fetchAll(
                db, sql: "SELECT id FROM coordinator_request WHERE closed_at IS NOT NULL AND closed_at < ?", arguments: [cutoff]
            )
            guard !ids.isEmpty else { return 0 }
            let placeholders = databaseQuestionMarks(count: ids.count)
            let reportIds = try Int64.fetchAll(
                db,
                sql: "SELECT report_id FROM request_event WHERE request_id IN (\(placeholders)) AND report_id IS NOT NULL",
                arguments: StatementArguments(ids)
            )
            try db.execute(sql: "DELETE FROM coordinator_request WHERE id IN (\(placeholders))", arguments: StatementArguments(ids))
            if !reportIds.isEmpty {
                try db.execute(
                    sql: "DELETE FROM report WHERE id IN (\(databaseQuestionMarks(count: reportIds.count)))",
                    arguments: StatementArguments(reportIds)
                )
            }
            return ids.count
        }
    }

    private static func trimmed(_ body: String) throws -> String {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw RequestError.emptyBody }
        return text
    }
}
