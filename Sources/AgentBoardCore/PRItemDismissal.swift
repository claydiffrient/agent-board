import Foundation
import GRDB

/// The payload of a `pr_item_dismissal` approval (SPEC §6 `dismiss_pr_item`).
public struct PRItemDismissalRequest: Codable, Sendable, Equatable {
    public var watchId: String
    public var itemId: Int64
    public var reason: String

    public init(watchId: String, itemId: Int64, reason: String) {
        self.watchId = watchId
        self.itemId = itemId
        self.reason = reason
    }

    public enum CodingKeys: String, CodingKey {
        case watchId = "watch_id"
        case itemId = "item_id"
        case reason
    }

    public func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    public static func decode(_ json: String?) throws -> PRItemDismissalRequest {
        guard let data = json?.data(using: .utf8) else { throw PRVerdictRejection("The approval carries no item.") }
        return try JSONDecoder().decode(PRItemDismissalRequest.self, from: data)
    }
}

extension PRItem {
    /// The first non-blank line of the body, cut to `limit`, so a person can tell items apart.
    public func firstLine(limit: Int = 100) -> String {
        let line = body.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? kind.rawValue
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }
}

extension PRWatchStore {
    public static let humanDismissal = "human"

    /// Retires one open item with a reason (SPEC §13.1 dismissed items): it leaves triage, every later
    /// check and the replies. A round left with nothing to fix or check ends, and a watch parked by a
    /// round whose items are now all gone unparks. Returns the watch as the dismissal left it.
    @discardableResult
    public func dismissItem(itemId: Int64, reason: String, by: String, now: Int64 = .nowMillis) throws -> PRWatch {
        try db.writer.write { try Self.dismissItem($0, itemId: itemId, reason: reason, by: by, now: now) }
    }

    static func dismissItem(_ db: Database, itemId: Int64, reason: String, by: String, now: Int64) throws -> PRWatch {
        guard let reason = nonBlank(reason)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw PRVerdictRejection("A dismissal needs a reason.")
        }
        guard var item = try PRItem.fetchOne(db, key: itemId), var watch = try PRWatch.fetchOne(db, key: item.watchId) else {
            throw PRVerdictRejection("Item \(itemId) not found.")
        }
        guard item.state == .open else {
            throw PRVerdictRejection("Item \(itemId) is \(item.state.rawValue), not open.")
        }
        item.state = .dismissed
        item.dismissReason = reason
        item.dismissedBy = by
        item.dismissedAt = now
        item.updatedAt = now
        try item.update(db)
        try settleAfterDismissal(db, watch: &watch, now: now)
        return watch
    }

    private static func settleAfterDismissal(_ db: Database, watch: inout PRWatch, now: Int64) throws {
        guard let round = try round(db, watchId: watch.id, number: watch.round), round.fixTaskId != nil,
              try checkItems(db, round: round).isEmpty
        else { return }
        let nextState: PRWatchState = try untriagedItemCount(db, watchId: watch.id) > 0
            || answeredFixCount(db, watchId: watch.id) > 0 ? .settling : .watching
        let itemBound: [PRRoundOutcome] = [.checkFailed, .checkUnavailable, .fixerFailed]
        switch watch.state {
        case .fixing, .checking:
            try endRound(db, watchId: watch.id, number: round.number, outcome: .triaged, now: now)
        case .parked where itemBound.map(\.rawValue).contains(round.outcome ?? ""):
            watch.parkedReason = nil
        default:
            return
        }
        for taskId in [round.fixTaskId, round.followupTaskId].compactMap({ $0 }) {
            guard let task = try Task.fetchOne(db, key: taskId), task.column != .done, task.column != .closed else {
                continue
            }
            try TaskStore.close(
                db, taskId, reason: "Round \(round.number) of #\(watch.number) has nothing left to fix: its items were dismissed.",
                by: "follow-through", at: now
            )
        }
        let wasParked = watch.state == .parked
        watch.state = nextState
        watch.updatedAt = now
        try watch.update(db)
        if !wasParked { try report(db, watch: watch, .round(number: round.number, outcome: .triaged)) }
    }

    static func pendingDismissal(_ db: Database, projectId: String, itemId: Int64) throws -> Approval? {
        try Approval.fetchAll(
            db,
            sql: """
            SELECT * FROM approval WHERE project_id = ? AND kind = ? AND resolved_at IS NULL
            ORDER BY created_at, rowid
            """,
            arguments: [projectId, ApprovalKind.prItemDismissal]
        ).first { (try? PRItemDismissalRequest.decode($0.payload).itemId) == itemId }
    }
}

extension Board {
    /// The only path that creates a `pr_item_dismissal` approval (SPEC §6 `dismiss_pr_item`): nothing
    /// changes until a human grants it. Another project's watch or item is not found, the same answer as
    /// an unknown one, and a pending request for the same item is returned as-is.
    @discardableResult
    public func requestItemDismissal(
        projectId: String, watchId: String, itemId: Int64, reason: String, requestedBy: String
    ) throws -> Approval {
        try db.writer.write { db in
            guard let watch = try PRWatch.filter(Column("id") == watchId && Column("project_id") == projectId).fetchOne(db)
            else { throw PRVerdictRejection("Pull request watch \(watchId) not found in this project.") }
            guard let item = try PRItem.fetchOne(db, key: itemId), item.watchId == watch.id else {
                throw PRVerdictRejection("Item \(itemId) not found on #\(watch.number).")
            }
            guard item.state == .open else {
                throw PRVerdictRejection("Item \(itemId) is \(item.state.rawValue), not open, so there is nothing to dismiss.")
            }
            guard let reason = PRWatchStore.nonBlank(reason)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw PRVerdictRejection("A dismissal needs a reason.")
            }
            if let existing = try PRWatchStore.pendingDismissal(db, projectId: projectId, itemId: itemId) {
                return existing
            }
            let source = [item.author, item.kind.rawValue].compactMap { $0 }.joined(separator: ", ")
            return try ApprovalStore.insert(
                db, projectId: projectId, kind: .prItemDismissal, taskId: nil, epicId: nil, requestedBy: requestedBy,
                reason: "#\(watch.number) \(watch.title)\nItem \(itemId) (\(source)): \(item.firstLine())\nReason: \(reason)",
                payload: try PRItemDismissalRequest(watchId: watch.id, itemId: itemId, reason: reason).encoded()
            )
        }
    }

    /// Runs a granted `pr_item_dismissal` and tells the orchestrator how it went as a `decision` report.
    /// A dismissal that can no longer apply, because the item reopened or left, is reported and rethrown.
    @discardableResult
    public func applyItemDismissal(_ approval: Approval, now: Int64 = .nowMillis) throws -> PRWatch {
        let request = try PRItemDismissalRequest.decode(approval.payload)
        do {
            return try db.writer.write { db in
                let before = try PRWatch.fetchOne(db, key: request.watchId)?.state
                let watch = try PRWatchStore.dismissItem(
                    db, itemId: request.itemId, reason: request.reason,
                    by: "orchestrator \(approval.requestedBy) via approval \(approval.id)", now: now
                )
                let moved = before == watch.state ? "" : " #\(watch.number) went from \(before?.rawValue ?? "?") to \(watch.state.rawValue)."
                _ = try ReportStore.insert(
                    db, projectId: approval.projectId, taskId: nil, sessionId: nil, kind: .decision,
                    body: "Item \(request.itemId) on #\(watch.number) dismissed: \(request.reason)\(moved)"
                )
                return watch
            }
        } catch {
            try db.writer.write { db in
                _ = try ReportStore.insert(
                    db, projectId: approval.projectId, taskId: nil, sessionId: nil, kind: .decision,
                    body: "Item \(request.itemId) was not dismissed: \(error.localizedDescription)"
                )
            }
            throw error
        }
    }
}
