import Foundation
import GRDB

/// One triage run (SPEC §13.2): the synthetic task its session is bound to, the watch it triages, and
/// the diff it was spawned to read. The grant's task id is the only route from a triager to a watch.
public struct PRTriage: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "pr_triage"

    public var taskId: String
    public var watchId: String
    public var baseOid: String
    public var headOid: String
    public var createdAt: Int64

    public init(taskId: String, watchId: String, baseOid: String, headOid: String, createdAt: Int64) {
        self.taskId = taskId
        self.watchId = watchId
        self.baseOid = baseOid
        self.headOid = headOid
        self.createdAt = createdAt
    }

    public enum CodingKeys: String, CodingKey {
        case taskId = "task_id"
        case watchId = "watch_id"
        case baseOid = "base_oid"
        case headOid = "head_oid"
        case createdAt = "created_at"
    }
}

/// One entry of a triager's `set_verdicts` call.
public struct PRVerdictInput: Sendable, Equatable {
    public var itemId: Int64
    public var verdict: PRItemVerdict
    public var approach: String
    public var replyBody: String?
    public var decisionQuestion: String?
    public var decisionOptions: [String]?

    public init(
        itemId: Int64, verdict: PRItemVerdict, approach: String, replyBody: String? = nil,
        decisionQuestion: String? = nil, decisionOptions: [String]? = nil
    ) {
        self.itemId = itemId
        self.verdict = verdict
        self.approach = approach
        self.replyBody = replyBody
        self.decisionQuestion = decisionQuestion
        self.decisionOptions = decisionOptions
    }
}

public struct PRVerdictRejection: LocalizedError, Sendable, Equatable {
    public var reason: String

    public init(_ reason: String) {
        self.reason = reason
    }

    public var errorDescription: String? { reason }
}

extension PRWatchStore {
    public func triage(taskId: String) throws -> PRTriage? {
        try db.reader.read { try PRTriage.fetchOne($0, key: taskId) }
    }

    public func openItems(watchId: String) throws -> [PRItem] {
        try items(watchId: watchId).filter { $0.state == .open }
    }

    /// Writes every verdict or none. Each item must be an open item of `watchId`, so a triager can
    /// reach no other watch. Returns the ids of the watch's open items still without a verdict.
    @discardableResult
    public func setVerdicts(_ verdicts: [PRVerdictInput], watchId: String, now: Int64 = .nowMillis) throws -> [Int64] {
        try db.writer.write { db in
            var updated: [PRItem] = []
            for input in verdicts {
                guard var item = try PRItem.fetchOne(db, key: input.itemId), item.watchId == watchId else {
                    throw PRVerdictRejection("Item \(input.itemId) is not one of this pull request's items.")
                }
                guard item.state == .open else {
                    throw PRVerdictRejection("Item \(input.itemId) is \(item.state.rawValue), not open.")
                }
                try Self.validate(input)
                item.verdict = input.verdict
                item.approach = input.approach
                item.replyBody = Self.nonBlank(input.replyBody)
                if input.verdict == .decision {
                    item.decisionQuestion = Self.nonBlank(input.decisionQuestion)
                    item.decisionOptionsJSON = Self.encodeOptions(input.decisionOptions ?? [])
                } else {
                    item.decisionQuestion = nil
                    item.decisionOptionsJSON = nil
                }
                item.updatedAt = now
                updated.append(item)
            }
            for item in updated { try item.update(db) }
            return try Int64.fetchAll(
                db,
                sql: "SELECT id FROM pr_item WHERE watch_id = ? AND state = 'open' AND verdict IS NULL ORDER BY id",
                arguments: [watchId]
            )
        }
    }

    static func validate(_ input: PRVerdictInput) throws {
        guard nonBlank(input.approach) != nil else {
            throw PRVerdictRejection("Item \(input.itemId) has no approach.")
        }
        guard input.verdict == .decision else { return }
        guard nonBlank(input.decisionQuestion) != nil else {
            throw PRVerdictRejection("Item \(input.itemId) is a decision with no decision_question.")
        }
        let options = (input.decisionOptions ?? []).compactMap(nonBlank)
        guard options.count >= 2 else {
            throw PRVerdictRejection("Item \(input.itemId) is a decision with fewer than two decision_options.")
        }
    }

    static func nonBlank(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    static func encodeOptions(_ options: [String]) -> String {
        let kept = options.compactMap(nonBlank)
        guard let data = try? JSONEncoder().encode(kept), let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }
}

extension Board {
    /// The task a triager is bound to, and its `pr_triage` row, in one transaction.
    public func createTriageTask(watchId: String, baseOid: String, headOid: String) throws -> Task {
        try db.writer.write { db in
            guard let watch = try PRWatch.fetchOne(db, key: watchId) else {
                throw PRVerdictRejection("No watched pull request \(watchId).")
            }
            let task = try TaskStore.insert(
                db, projectId: watch.projectId, title: "Triage #\(watch.number): \(watch.title)", body: nil,
                acceptance: nil, priority: nil, column: .ready, origin: .triage, epicId: nil
            )
            try PRTriage(
                taskId: task.id, watchId: watchId, baseOid: baseOid, headOid: headOid, createdAt: .nowMillis
            ).insert(db)
            return task
        }
    }

    /// Ends a triage once every open item has a verdict: the session completes, its grant is
    /// revoked, and the task goes to `done` with no report, since nothing on the board asked for it.
    public func finishTriage(taskId: String, sessionId: String?, summary: String) throws {
        try db.writer.write { db in
            let task = try Self.requireTask(db, taskId)
            guard task.origin == .triage else {
                throw BoardError.invalidTransition(taskId: taskId, from: task.column, to: .done)
            }
            if let sessionId, let session = try AgentSession.fetchOne(db, key: sessionId), session.state.isActive {
                try SessionStore.setState(db, sessionId, .completed, endedAt: .nowMillis)
                try FileLockStore.releaseAll(db, sessionId: sessionId)
                try TokenGrantStore.revokeAll(db, sessionId: sessionId)
            }
            _ = try ProgressStore.append(db, taskId: taskId, sessionId: sessionId, kind: .note, text: summary)
            try TaskStore.setBlocked(db, taskId, false, reason: nil)
            try TaskStore.move(db, taskId, to: .done, before: nil)
        }
    }
}
