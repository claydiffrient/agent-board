import Foundation
import GRDB

/// One entry of a follow-up checker's `set_followup_grades` call.
public struct PRGradeInput: Sendable, Equatable {
    public var itemId: Int64
    public var grade: PRFollowupGrade
    public var note: String

    public init(itemId: Int64, grade: PRFollowupGrade, note: String) {
        self.itemId = itemId
        self.grade = grade
        self.note = note
    }
}

extension PRWatchStore {
    /// Failed checks in one round that park its watch (SPEC §13.1): the first two reopen the fixer.
    public static let failedChecksBeforePark = 3

    public func currentRound(watchId: String) throws -> PRRound? {
        try db.reader.read { db in
            guard let watch = try PRWatch.fetchOne(db, key: watchId) else { return nil }
            return try Self.round(db, watchId: watchId, number: watch.round)
        }
    }

    public func round(followupTaskId: String) throws -> PRRound? {
        try db.reader.read { try PRRound.filter(Column("followup_task_id") == followupTaskId).fetchOne($0) }
    }

    /// The items a round's check grades: the open `fix` items its fixer task was given, in task-body order.
    public func checkItems(round: PRRound) throws -> [PRItem] {
        try db.reader.read { try Self.checkItems($0, round: round) }
    }

    static func round(_ db: Database, watchId: String, number: Int) throws -> PRRound? {
        try PRRound.filter(Column("watch_id") == watchId && Column("number") == number).fetchOne(db)
    }

    static func checkItems(_ db: Database, round: PRRound) throws -> [PRItem] {
        guard let taskId = round.fixTaskId else { return [] }
        return try PRItem.filter(
            Column("watch_id") == round.watchId && Column("fix_task_id") == taskId
                && Column("state") == PRItemState.open && Column("verdict") == PRItemVerdict.fix
        ).order(Column("id")).fetchAll(db)
    }

    /// Writes every grade or none. Each item must be one its round's check grades, so a checker reaches
    /// no other item. Returns the ids of that round's items still without a grade.
    @discardableResult
    public func setFollowupGrades(_ grades: [PRGradeInput], taskId: String, now: Int64 = .nowMillis) throws -> [Int64] {
        try db.writer.write { db in
            guard let round = try PRRound.filter(Column("followup_task_id") == taskId).fetchOne(db) else {
                throw PRVerdictRejection("This follow-up check has no round.")
            }
            let items = Dictionary(uniqueKeysWithValues: try Self.checkItems(db, round: round).map { ($0.id ?? 0, $0) })
            var updated: [PRItem] = []
            for input in grades {
                guard var item = items[input.itemId] else {
                    throw PRVerdictRejection("Item \(input.itemId) is not one of the items this round fixed.")
                }
                guard let note = Self.nonBlank(input.note) else {
                    throw PRVerdictRejection("Item \(input.itemId) has no evidence.")
                }
                item.followupGrade = input.grade
                item.followupNote = note
                item.updatedAt = now
                updated.append(item)
            }
            for item in updated { try item.update(db) }
            return try Self.checkItems(db, round: round).filter { $0.followupGrade == nil }.compactMap(\.id)
        }
    }

    /// A shutdown order stops a running follow-up check; the round's check starts a fresh one once it lifts.
    public func interruptFollowupCheck(taskId: String) throws {
        try db.writer.write { db in
            try db.execute(
                sql: "UPDATE pr_round SET followup_task_id = NULL, checked_head_oid = NULL WHERE followup_task_id = ?",
                arguments: [taskId]
            )
        }
    }

    /// Fixing → checking once the round's fixer reports (SPEC §13.1), clearing the last check's verdict
    /// and grades. Nothing moves unless the task is the fixing round's own.
    static func beginCheck(_ db: Database, fixTaskId: String, now: Int64) throws {
        guard var round = try PRRound.filter(Column("fix_task_id") == fixTaskId).fetchOne(db),
              var watch = try PRWatch.fetchOne(db, key: round.watchId),
              watch.state == .fixing, watch.round == round.number
        else { return }
        round.reviewVerdict = nil
        round.reviewFindings = nil
        round.followupTaskId = nil
        round.checkedHeadOid = nil
        try round.update(db)
        try db.execute(
            sql: "UPDATE pr_item SET followup_grade = NULL, followup_note = NULL, updated_at = ? WHERE fix_task_id = ?",
            arguments: [now, fixTaskId]
        )
        watch.state = .checking
        watch.updatedAt = now
        try watch.update(db)
    }
}

extension Board {
    /// SPEC §13.1 checking: a fixer's report holds its task in `review` for the round's check, never for
    /// the review queue or an acceptance, and moves the watch on to checking. The report is recorded
    /// already consumed, since the orchestrator never asked for the round.
    static func completeFixRound(
        _ db: Database, task: Task, sessionId: String, summary: String
    ) throws -> CompletionOutcome {
        let report = try ReportStore.insert(
            db, projectId: task.projectId, taskId: task.id, sessionId: sessionId, kind: .complete, body: summary
        )
        try db.execute(sql: "UPDATE report SET consumed_at = ? WHERE id = ?", arguments: [Int64.nowMillis, report.id])
        try TaskStore.setBlocked(db, task.id, false, reason: nil)
        try TaskStore.move(db, task.id, to: .review, before: nil)
        try SessionStore.setState(db, sessionId, .completed, endedAt: .nowMillis)
        try FileLockStore.releaseAll(db, sessionId: sessionId)
        try PRWatchStore.beginCheck(db, fixTaskId: task.id, now: .nowMillis)
        return CompletionOutcome(
            report: report, level: try ReviewPolicy.level(db, task: task),
            routing: try ReviewPolicy.fixRoundRouting(db, projectId: task.projectId), column: .review,
            wasAlreadyComplete: false
        )
    }

    /// Who reviews a round under check. An agent is recorded as the task's reviewer before it is spawned.
    public func assignRoundReviewer(taskId: String) throws -> ReviewRouting {
        try db.writer.write { db in
            let task = try Self.requireTask(db, taskId)
            guard task.column == .review else { throw BoardError.taskNotInReview(taskId: taskId, column: task.column) }
            let routing = try ReviewPolicy.fixRoundRouting(db, projectId: task.projectId)
            if case .agentReview(let agentId, let agentName) = routing {
                try TaskStore.setReviewer(db, taskId, agentId)
                _ = try ProgressStore.append(
                    db, taskId: taskId, sessionId: nil, kind: .status,
                    text: "Handed to rostered reviewer \(agentName) for this round's check."
                )
            }
            return routing
        }
    }

    public static let roundReviewLead = "Round review."

    /// A reviewer's verdict on a round under check. It moves nothing: `settleCheck` decides the round once
    /// the follow-up check is in too. The reviewer's session ends as any verdict ends it.
    public func recordRoundReview(
        taskId: String, sessionId: String?, reviewerName: String, accepted: Bool, text: String, now: Int64 = .nowMillis
    ) throws {
        try db.writer.write { db in
            let task = try Self.requireTask(db, taskId)
            guard task.column == .review,
                  var round = try PRRound.filter(Column("fix_task_id") == taskId).fetchOne(db),
                  let watch = try PRWatch.fetchOne(db, key: round.watchId),
                  watch.state == .checking, watch.round == round.number, round.reviewVerdict == nil
            else {
                throw PRVerdictRejection("Task \(taskId) is not a round waiting on its review.")
            }
            round.reviewVerdict = accepted ? .accepted : .reopened
            round.reviewFindings = accepted ? nil : "Reviewer \(reviewerName) reopened it:\n\n\(text)"
            try round.update(db)
            _ = try ProgressStore.append(
                db, taskId: taskId, sessionId: sessionId, kind: .note,
                text: "\(Self.roundReviewLead) Reviewer \(reviewerName) \(accepted ? "accepted" : "reopened") round "
                    + "\(round.number).\n\n\(text)"
            )
            if let sessionId { try Self.finishReview(db, sessionId: sessionId) }
        }
    }

    /// The task a round's follow-up checker is bound to, recorded on the round with the head it judges.
    /// Nil unless the watch is checking, its round has no follow-up check, and the round has items to grade.
    public func createFollowupCheckTask(watchId: String, headOid: String) throws -> Task? {
        try db.writer.write { db in
            guard let watch = try PRWatch.fetchOne(db, key: watchId), watch.state == .checking,
                  var round = try PRWatchStore.round(db, watchId: watchId, number: watch.round),
                  round.followupTaskId == nil, !(try PRWatchStore.checkItems(db, round: round)).isEmpty
            else { return nil }
            let task = try TaskStore.insert(
                db, projectId: watch.projectId,
                title: "Follow-up check of round \(round.number) of #\(watch.number): \(watch.title)", body: nil,
                acceptance: nil, priority: nil, column: .ready, origin: .followupCheck, epicId: nil
            )
            round.followupTaskId = task.id
            round.checkedHeadOid = headOid
            try round.update(db)
            return task
        }
    }

    /// Checking's decision (SPEC §13.1), once the review is in and every item is graded. A pass sends the
    /// task to `done` and the watch to publishing. Anything else is a failed check: the first two put the
    /// findings on the task, where the next fixer's opening prompt reads them, and send it back to fixing;
    /// the third parks the watch. Nil while either half is still out.
    @discardableResult
    public func settleCheck(watchId: String, now: Int64 = .nowMillis) throws -> PRWatchState? {
        try db.writer.write { db in
            guard var watch = try PRWatch.fetchOne(db, key: watchId), watch.state == .checking,
                  var round = try PRWatchStore.round(db, watchId: watchId, number: watch.round),
                  let taskId = round.fixTaskId, let task = try Task.fetchOne(db, key: taskId), task.column == .review,
                  let review = round.reviewVerdict
            else { return nil }
            let items = try PRWatchStore.checkItems(db, round: round)
            if !items.isEmpty {
                guard let checkId = round.followupTaskId, try Task.fetchOne(db, key: checkId)?.column == .done else {
                    return nil
                }
            }
            let unfixed = items.enumerated().filter { $0.element.followupGrade != .fixed && $0.element.followupGrade != .moot }
            if review == .accepted, unfixed.isEmpty {
                _ = try ProgressStore.append(
                    db, taskId: taskId, sessionId: nil, kind: .note,
                    text: "\(Self.reviewPassedLead) Round \(round.number) passed its check: the reviewer accepted it "
                        + "and every item is fixed or moot."
                )
                try TaskStore.move(db, taskId, to: .done, before: nil)
                watch.state = .publishing
                watch.updatedAt = now
                try watch.update(db)
                return watch.state
            }

            round.checkFailures += 1
            let failures = round.checkFailures
            var findings = [round.reviewFindings].compactMap { $0 }
            if !unfixed.isEmpty {
                findings.append("The follow-up check graded these items short of fixed:\n" + unfixed.map { offset, item in
                    "- Item \(offset + 1): \(item.followupGrade?.rawValue ?? "ungraded") — \(item.followupNote ?? "no evidence")"
                }.joined(separator: "\n"))
            }
            let text = "\(Self.reviewFailedLead) Round \(round.number)'s check failed (\(failures) of "
                + "\(PRWatchStore.failedChecksBeforePark)).\n\n" + findings.joined(separator: "\n\n")
            _ = try ProgressStore.append(db, taskId: taskId, sessionId: nil, kind: .note, text: text)
            if failures >= PRWatchStore.failedChecksBeforePark {
                try round.update(db)
                try Self.parkRound(
                    db, watch: &watch, round: round,
                    reason: "Round \(round.number) failed its check \(failures) times. The last:\n\n"
                        + findings.joined(separator: "\n\n"),
                    now: now
                )
                return watch.state
            }
            try round.update(db)
            try TaskStore.setReviewer(db, taskId, nil)
            try TaskStore.setFailed(db, taskId, false, reason: nil)
            try TaskStore.move(db, taskId, to: .ready, before: nil)
            watch.state = .fixing
            watch.updatedAt = now
            try watch.update(db)
            return watch.state
        }
    }

    /// Parks a checking watch whose round cannot be checked, closing its fix task so no person is left
    /// a review card nothing can accept.
    public func parkCheck(watchId: String, reason: String, now: Int64 = .nowMillis) throws {
        try db.writer.write { db in
            guard var watch = try PRWatch.fetchOne(db, key: watchId), watch.state == .checking,
                  let round = try PRWatchStore.round(db, watchId: watchId, number: watch.round)
            else { return }
            try Self.parkRound(db, watch: &watch, round: round, reason: reason, now: now)
        }
    }

    /// SPEC §13.1 parked: a fixing round whose last `failedSessionsBeforePark` fixer sessions each ended
    /// without a report parks, naming the last one's stop reason. A session wound down for a shutdown order
    /// is not a failure and does not break the run. Returns whether it parked.
    public func parkIfFixersFailing(watchId: String, now: Int64 = .nowMillis) throws -> Bool {
        try db.writer.write { db in
            guard var watch = try PRWatch.fetchOne(db, key: watchId), watch.state == .fixing,
                  let round = try PRWatchStore.round(db, watchId: watchId, number: watch.round),
                  let taskId = round.fixTaskId
            else { return false }
            let windDown = SessionTermination.shutdownAcknowledged(note: nil).reason
            let fixers = try AgentSession.fetchAll(
                db,
                sql: """
                SELECT * FROM agent_session WHERE task_id = ? AND review_head IS NULL
                ORDER BY started_at DESC, attempt DESC
                """,
                arguments: [taskId]
            ).filter { $0.stopReason != windDown }
            let failed = fixers.prefix { !$0.state.isActive && $0.state != .completed }
            guard failed.count >= PRWatchStore.failedSessionsBeforePark else { return false }
            try Self.parkRound(
                db, watch: &watch, round: round, outcome: .fixerFailed,
                reason: "Round \(round.number)'s fixer ended without a report \(failed.count) times in a row. The last: "
                    + (failed.first?.stopReason ?? "no reason recorded"),
                now: now
            )
            return true
        }
    }

    private static func parkRound(
        _ db: Database, watch: inout PRWatch, round: PRRound, outcome: PRRoundOutcome = .checkFailed,
        reason: String, now: Int64
    ) throws {
        try PRWatchStore.endRound(db, watchId: watch.id, number: round.number, outcome: outcome, now: now)
        for taskId in [round.fixTaskId, round.followupTaskId].compactMap({ $0 }) {
            guard let task = try Task.fetchOne(db, key: taskId), task.column != .done, task.column != .closed,
                  try SessionStore.activeHolder(db, taskId: taskId) == nil
            else { continue }
            try TaskStore.close(db, taskId, reason: "Pull request #\(watch.number) parked: \(reason)", by: "follow-through", at: now)
        }
        watch.state = .parked
        watch.parkedReason = reason
        watch.updatedAt = now
        try watch.update(db)
    }

    /// A fixing round left with no task and no open fix item, every one answered or reopened for triage
    /// before its fixer was created, ends there: settling if feedback awaits triage, else watching.
    @discardableResult
    public func endFixRoundWithoutFixes(watchId: String, now: Int64 = .nowMillis) throws -> PRWatchState? {
        try db.writer.write { db in
            guard var watch = try PRWatch.fetchOne(db, key: watchId), watch.state == .fixing,
                  let round = try PRWatchStore.round(db, watchId: watchId, number: watch.round), round.fixTaskId == nil,
                  try PRItem.filter(
                      Column("watch_id") == watchId && Column("state") == PRItemState.open
                          && Column("verdict") == PRItemVerdict.fix
                  ).fetchCount(db) == 0
            else { return nil }
            try PRWatchStore.endRound(db, watchId: watchId, number: round.number, outcome: .triaged, now: now)
            watch.state = try PRWatchStore.untriagedItemCount(db, watchId: watchId) > 0 ? .settling : .watching
            watch.updatedAt = now
            try watch.update(db)
            return watch.state
        }
    }
}
