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
        try settleAfterDismissal(db, watch: &watch, itemId: itemId, reason: reason, now: now)
        return watch
    }

    /// The fix and follow-up check tasks that dismissing `itemId` would close, so a caller can stop any
    /// session still working them first (SPEC §13.1 dismissed items).
    public func tasksClosedByDismissing(itemId: Int64) throws -> [String] {
        try db.reader.read { db in
            guard let item = try PRItem.fetchOne(db, key: itemId), item.state == .open,
                  let watch = try PRWatch.fetchOne(db, key: item.watchId),
                  let round = try Self.roundSettled(db, watch: watch, dismissing: itemId)
            else { return [] }
            return [round.fixTaskId, round.followupTaskId].compactMap { $0 }
        }
    }

    private static let itemBoundParks = Set([PRRoundOutcome.checkFailed, .checkUnavailable, .fixerFailed].map(\.rawValue))

    /// The round a dismissal of `itemId` ends, or whose park it lifts, because no other item holds it.
    private static func roundSettled(_ db: Database, watch: PRWatch, dismissing itemId: Int64) throws -> PRRound? {
        guard let round = try round(db, watchId: watch.id, number: watch.round), round.fixTaskId != nil,
              try checkItems(db, round: round).allSatisfy({ $0.id == itemId })
        else { return nil }
        switch watch.state {
        case .fixing, .checking: return round
        case .parked where itemBoundParks.contains(round.outcome ?? ""): return round
        default: return nil
        }
    }

    private static func settleAfterDismissal(
        _ db: Database, watch: inout PRWatch, itemId: Int64, reason: String, now: Int64
    ) throws {
        guard let round = try roundSettled(db, watch: watch, dismissing: itemId) else { return }
        let wasParked = watch.state == .parked
        if wasParked {
            watch.parkedReason = nil
        } else {
            try endRound(db, watchId: watch.id, number: round.number, outcome: .triaged, now: now)
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
        watch.state = try untriagedItemCount(db, watchId: watch.id) > 0
            || answeredFixCount(db, watchId: watch.id) > 0 ? .settling : .watching
        watch.updatedAt = now
        try watch.update(db)
        try report(
            db, watch: watch,
            wasParked ? .unparked(reason: "item \(itemId) dismissed: \(reason)") : .round(number: round.number, outcome: .triaged)
        )
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
            try reportItemNotDismissed(request, projectId: approval.projectId, because: error.localizedDescription)
            throw error
        }
    }

    /// The `decision` report for a granted dismissal that did not happen, naming why.
    public func reportItemNotDismissed(_ request: PRItemDismissalRequest, projectId: String, because cause: String) throws {
        try db.writer.write { db in
            _ = try ReportStore.insert(
                db, projectId: projectId, taskId: nil, sessionId: nil, kind: .decision,
                body: "Item \(request.itemId) was not dismissed: \(cause)"
            )
        }
    }
}
