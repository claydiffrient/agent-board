import Foundation
import GRDB

extension Board {
    /// Answers an open decision from the Pull Requests page's Needs you group (SPEC §13.4). The
    /// answer is kept in `decision_answer`, and the item moves to the next round with the answer as
    /// its approach: as a `fix` when the human chose one of triage's options, which gets its backlog
    /// code task the way a triaged fix does, or as a handled `answer` when they typed a reply, which
    /// becomes its `reply_body`.
    @discardableResult
    public func answerDecision(
        itemId: Int64, answer: String, verdict: PRItemVerdict, fixerModel: String?, now: Int64 = .nowMillis
    ) throws -> PRItem {
        guard verdict == .fix || verdict == .answer else {
            throw PRVerdictRejection("A decision is answered as fix or answer, not \(verdict.rawValue).")
        }
        let answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw PRVerdictRejection("The answer is empty.") }
        return try db.writer.write { db in
            guard var item = try PRItem.fetchOne(db, key: itemId), item.isOpenDecision,
                  let watch = try PRWatch.fetchOne(db, key: item.watchId)
            else { throw PRVerdictRejection("Item \(itemId) is no longer an open decision.") }
            item.decisionAnswer = answer
            item.verdict = verdict
            item.approach = answer
            item.replyBody = verdict == .answer ? answer : nil
            item.round = watch.round + 1
            _ = try Self.applyVerdict(db, to: &item, watch: watch, fixerModel: fixerModel, now: now)
            item.updatedAt = now
            try item.update(db)
            return item
        }
    }
}
