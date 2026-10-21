import Foundation
import GRDB

extension PRItem {
    /// The node id of the item a head's failed checks become: one per head, since a rollup has no id.
    public static func checksNodeId(head: String) -> String { "checks:\(head)" }

    /// What publishing posts for this item (SPEC §13.2), or nil when it has nothing factual to say.
    public func factualReply(pushedHeadOid: String?) -> String? {
        switch verdict {
        case .fix?:
            return pushedHeadOid.map { "Fixed in \($0.prefix(7))." }
        case .answer?, .alreadyDone?, .followUp?:
            return PRWatchStore.nonBlank(replyBody)
        case .decision?, nil:
            return nil
        }
    }
}

extension PRWatchStore {
    /// Marks the frozen decisions SPEC §13.1 verified makes, so removing the label can send them back to triage.
    public static let verifiedFreezeApproach = "Arrived after the pull request was verified, so follow-through will not change it."
    static let verifiedFreezeQuestion = "This pull request is verified, so Agent Board will not push to it. "
        + "Handle this feedback yourself, or remove the verification label to send it to triage."
    static let verifiedFreezeOptions = ["Handle it myself", "Remove the label and let follow-through fix it"]

    /// SPEC §13.1 verified: open feedback with no verdict on a verified watch becomes a decision rather than
    /// a round, and once the watch is no longer verified those decisions are untriaged again.
    public func applyVerifiedFreeze(watchId: String, now: Int64 = .nowMillis) throws {
        try db.writer.write { db in
            guard let watch = try PRWatch.fetchOne(db, key: watchId) else { return }
            if watch.state == .verified {
                try Self.freeze(db, sql: "watch_id = ? AND state = 'open' AND verdict IS NULL", arguments: [watchId], now: now)
            } else {
                try db.execute(
                    sql: """
                    UPDATE pr_item SET verdict = NULL, approach = NULL, decision_question = NULL,
                    decision_options_json = NULL, updated_at = ?
                    WHERE watch_id = ? AND state = 'open' AND verdict = 'decision' AND approach = ?
                    """,
                    arguments: [now, watchId, Self.verifiedFreezeApproach]
                )
            }
        }
    }

    static func freeze(_ db: Database, sql condition: String, arguments: StatementArguments, now: Int64) throws {
        var values: StatementArguments = [
            verifiedFreezeApproach, verifiedFreezeQuestion, encodeOptions(verifiedFreezeOptions), now,
        ]
        values += arguments
        try db.execute(
            sql: """
            UPDATE pr_item SET verdict = 'decision', approach = ?, decision_question = ?, decision_options_json = ?,
            fix_task_id = NULL, followup_grade = NULL, followup_note = NULL, updated_at = ?
            WHERE \(condition)
            """,
            arguments: values
        )
    }

    /// SPEC §13.1 awaitingCI, once GitHub reports the pushed head: green goes to watching, and red to
    /// watching with a failed-checks decision item. A head GitHub has not caught up to yet waits; any
    /// other head means someone pushed over the round, and the watch goes back to watching.
    @discardableResult
    public func settleAwaitingCI(watchId: String, now: Int64 = .nowMillis) throws -> PRWatchState? {
        try db.writer.write { db in
            guard var watch = try PRWatch.fetchOne(db, key: watchId), watch.state == .awaitingCI,
                  let round = try Self.round(db, watchId: watchId, number: watch.round)
            else { return nil }
            if watch.headOid == round.pushedHeadOid {
                if PRWatchTransition.checksFailed(watch.checksState) {
                    let nodeId = PRItem.checksNodeId(head: watch.headOid)
                    if try PRItem.filter(Column("watch_id") == watchId && Column("github_node_id") == nodeId).fetchCount(db) == 0 {
                        var item = PRItem(
                            id: nil, watchId: watchId, githubNodeId: nodeId, kind: .check, author: nil,
                            body: "Checks failed on \(watch.headOid.prefix(7)) after round \(round.number) was pushed: "
                                + "the status check rollup is \(watch.checksState ?? "unknown").",
                            path: nil, line: nil, url: watch.url, state: .open, verdict: .decision,
                            approach: "Follow-through does not triage failed checks yet.",
                            decisionQuestion: "Checks failed after round \(round.number) was pushed. Fix them on the "
                                + "pull request yourself, or push nothing and let new review feedback start the next round.",
                            decisionOptionsJSON: Self.encodeOptions(["Fix the checks myself", "Wait for review feedback"]),
                            round: round.number, createdAt: now, updatedAt: now
                        )
                        try item.insert(db)
                    }
                } else if !PRWatchTransition.checksGreen(watch.checksState) {
                    return nil
                }
            } else if watch.headOid == round.baseHeadOid {
                return nil
            }
            watch.state = .watching
            watch.updatedAt = now
            try watch.update(db)
            return watch.state
        }
    }

    /// A round's handled thread and review items with a factual reply not yet posted.
    public func pendingReplies(watchId: String, round: Int) throws -> [PRItem] {
        try db.reader.read { db in
            try PRItem.filter(
                Column("watch_id") == watchId && Column("round") == round && Column("state") == PRItemState.handled
                    && Column("reply_url") == nil && [PRItemKind.thread, PRItemKind.review].contains(Column("kind"))
            ).order(Column("id")).fetchAll(db)
        }
    }

    public func recordReply(itemId: Int64, url: String, now: Int64 = .nowMillis) throws {
        try db.writer.write { db in
            try db.execute(
                sql: "UPDATE pr_item SET reply_url = ?, updated_at = ? WHERE id = ?", arguments: [url, now, itemId]
            )
        }
    }
}

extension Board {
    /// Publishing's push landed (SPEC §13.1): the round ends `published` with the head it pushed, its fix
    /// items are handled in it, and the watch waits on CI. Nil unless the watch is publishing.
    @discardableResult
    public func recordRoundPublished(watchId: String, pushedHeadOid: String, now: Int64 = .nowMillis) throws -> PRRound? {
        try db.writer.write { db in
            guard var watch = try PRWatch.fetchOne(db, key: watchId), watch.state == .publishing,
                  var round = try PRWatchStore.round(db, watchId: watchId, number: watch.round)
            else { return nil }
            round.pushedHeadOid = pushedHeadOid
            try round.update(db)
            try PRWatchStore.endRound(db, watchId: watchId, number: round.number, outcome: .published, now: now)
            if let taskId = round.fixTaskId {
                try db.execute(
                    sql: """
                    UPDATE pr_item SET state = 'handled', round = ?, updated_at = ?
                    WHERE watch_id = ? AND fix_task_id = ? AND state = 'open' AND verdict = 'fix'
                    """,
                    arguments: [round.number, now, watchId, taskId]
                )
            }
            watch.state = .awaitingCI
            watch.updatedAt = now
            try watch.update(db)
            return round
        }
    }

    /// The head moved under a publishing round (SPEC §13.1 stale): nothing is pushed, the round's fix items
    /// go back to triage against the new head, and the watch settles.
    public func markRoundStale(watchId: String, now: Int64 = .nowMillis) throws {
        try endPublishing(watchId: watchId, outcome: .stale, state: .settling, now: now) { db, watch, round in
            guard let taskId = round.fixTaskId else { return }
            try db.execute(
                sql: """
                UPDATE pr_item SET verdict = NULL, approach = NULL, fix_task_id = NULL, followup_grade = NULL,
                followup_note = NULL, updated_at = ?
                WHERE watch_id = ? AND fix_task_id = ? AND state = 'open' AND verdict = 'fix'
                """,
                arguments: [now, watch.id, taskId]
            )
        }
    }

    /// The verification label was on the pull request when its round came to publish: the PR is frozen,
    /// so nothing is pushed and the round's fix items become decisions (SPEC §13.1 verified).
    public func freezeRound(watchId: String, now: Int64 = .nowMillis) throws {
        try endPublishing(watchId: watchId, outcome: .frozen, state: .verified, now: now) { db, watch, round in
            guard let taskId = round.fixTaskId else { return }
            try PRWatchStore.freeze(
                db, sql: "watch_id = ? AND fix_task_id = ? AND state = 'open' AND verdict = 'fix'",
                arguments: [watch.id, taskId], now: now
            )
        }
    }

    public func parkPublishing(watchId: String, reason: String, now: Int64 = .nowMillis) throws {
        try endPublishing(watchId: watchId, outcome: .publishFailed, state: .parked, now: now) { _, watch, _ in
            watch.parkedReason = reason
        }
    }

    private func endPublishing(
        watchId: String, outcome: PRRoundOutcome, state: PRWatchState, now: Int64,
        _ body: (Database, inout PRWatch, PRRound) throws -> Void
    ) throws {
        try db.writer.write { db in
            guard var watch = try PRWatch.fetchOne(db, key: watchId), watch.state == .publishing,
                  let round = try PRWatchStore.round(db, watchId: watchId, number: watch.round)
            else { return }
            try PRWatchStore.endRound(db, watchId: watchId, number: round.number, outcome: outcome, now: now)
            try body(db, &watch, round)
            if state == .verified, watch.verifiedAt == nil { watch.verifiedAt = now }
            watch.state = state
            watch.updatedAt = now
            try watch.update(db)
        }
    }
}
