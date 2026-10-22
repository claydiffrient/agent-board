import Foundation
import GRDB

extension PRItem {
    /// The node id of a head's merge conflict with its base, which GitHub gives no id of its own.
    public static func conflictNodeId(head: String) -> String { "conflict:\(head)" }

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
    static let verifiedFreezeOptions = [
        PRDecisionOption(label: "Handle it myself", verdict: .answer),
        PRDecisionOption(label: "Remove the label and let follow-through fix it", verdict: .fix),
    ]

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
    /// settling with an untriaged `check` item for each of `failedChecks` not yet recorded, which triage takes
    /// up without the settle wait. Red with no new failed check goes to watching. A head GitHub has not
    /// caught up to yet waits; any other head means someone pushed over the round, and the watch goes back
    /// to watching.
    @discardableResult
    public func settleAwaitingCI(
        watchId: String, failedChecks: [PRFailedCheck] = [], now: Int64 = .nowMillis
    ) throws -> PRWatchState? {
        try db.writer.write { db in
            guard var watch = try PRWatch.fetchOne(db, key: watchId), watch.state == .awaitingCI,
                  let round = try Self.round(db, watchId: watchId, number: watch.round)
            else { return nil }
            watch.state = .watching
            if watch.headOid == round.pushedHeadOid {
                if PRWatchTransition.checksFailed(watch.checksState) {
                    let known = Set(try String.fetchAll(
                        db, sql: "SELECT github_node_id FROM pr_item WHERE watch_id = ?", arguments: [watchId]
                    ))
                    for check in failedChecks where !known.contains(check.githubNodeId) {
                        var item = PRItem(
                            id: nil, watchId: watchId, githubNodeId: check.githubNodeId, kind: .check, author: nil,
                            body: check.itemBody(head: watch.headOid), path: nil, line: nil, url: check.url,
                            state: .open, round: watch.round, createdAt: now, updatedAt: now
                        )
                        try item.insert(db)
                        watch.state = .settling
                        watch.lastFeedbackAt = now
                    }
                } else if !PRWatchTransition.checksGreen(
                    watch.checksState, headSeenAt: watch.headChangedAt ?? watch.createdAt, now: now
                ) {
                    return nil
                }
            } else if watch.headOid == round.baseHeadOid {
                return nil
            }
            watch.updatedAt = now
            try watch.update(db)
            return watch.state
        }
    }

    /// Every handled thread and review item, from any round, with a factual reply not yet posted (SPEC
    /// §13.2), handled since `postFactualReplies` was last turned on and not given up on. A `fix` item
    /// qualifies only once its own round pushed it, so a stale or parked round's fixes never claim
    /// "Fixed in"; `IS` keeps that match when the round's fix task was deleted and both sides are null.
    public func pendingReplies(watchId: String) throws -> [PRItem] {
        try db.reader.read { db in
            try PRItem.fetchAll(
                db,
                sql: """
                SELECT i.* FROM pr_item i
                JOIN pr_watch w ON w.id = i.watch_id
                JOIN project p ON p.id = w.project_id
                WHERE i.watch_id = ? AND i.state = 'handled' AND i.reply_url IS NULL AND i.reply_abandoned_at IS NULL
                AND i.kind IN ('thread', 'review')
                AND i.handled_at >= json_extract(p.settings_json, '$.prFollowThrough.postFactualRepliesSince')
                AND (
                  (i.verdict IN ('answer', 'already_done', 'follow_up') AND i.reply_body IS NOT NULL)
                  OR (i.verdict = 'fix' AND EXISTS (
                    SELECT 1 FROM pr_round r WHERE r.watch_id = i.watch_id AND r.number = i.round
                    AND r.pushed_head_oid IS NOT NULL AND r.fix_task_id IS i.fix_task_id
                  ))
                )
                ORDER BY i.id
                """,
                arguments: [watchId]
            )
        }
    }

    public func recordReply(itemId: Int64, url: String, now: Int64 = .nowMillis) throws {
        try db.writer.write { db in
            try db.execute(
                sql: "UPDATE pr_item SET reply_url = ?, reply_error = NULL, updated_at = ? WHERE id = ?",
                arguments: [url, now, itemId]
            )
        }
    }

    /// A post that failed. One whose comment is `gone` from GitHub is abandoned; any other is tried again
    /// at the next posting point.
    public func recordReplyFailure(itemId: Int64, error: String, gone: Bool, now: Int64 = .nowMillis) throws {
        try db.writer.write { db in
            try db.execute(
                sql: "UPDATE pr_item SET reply_error = ?, reply_abandoned_at = ?, updated_at = ? WHERE id = ?",
                arguments: [error, gone ? now : nil, now, itemId]
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
                    UPDATE pr_item SET state = 'handled', round = ?, handled_at = ?, updated_at = ?
                    WHERE watch_id = ? AND fix_task_id = ? AND state = 'open' AND verdict = 'fix'
                    """,
                    arguments: [round.number, now, now, watchId, taskId]
                )
            }
            watch.state = .awaitingCI
            watch.updatedAt = now
            try watch.update(db)
            try PRWatchStore.report(
                db, watch: watch, .round(number: round.number, outcome: .published, pushedHeadOid: pushedHeadOid)
            )
            return round
        }
    }

    /// The head moved under a publishing round (SPEC §13.1 stale): nothing is pushed, the round's fix items
    /// go back to triage against the new head, and the watch is stale until the next poll settles it.
    public func markRoundStale(watchId: String, now: Int64 = .nowMillis) throws {
        try endPublishing(watchId: watchId, outcome: .stale, state: .stale, now: now) { db, watch, round in
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
            if outcome == .stale { try PRWatchStore.report(db, watch: watch, .round(number: round.number, outcome: .stale)) }
            if state == .parked { try PRWatchStore.report(db, watch: watch, .parked(reason: watch.parkedReason)) }
        }
    }
}
