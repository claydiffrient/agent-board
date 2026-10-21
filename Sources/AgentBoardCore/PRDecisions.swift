import Foundation
import GRDB

/// How the human answered a decision: one of triage's options, by label, or a typed reply.
public enum PRDecisionChoice: Sendable, Equatable {
    case option(String)
    case reply(String)
}

extension Board {
    /// Answers an open decision from the Pull Requests page's Needs you group (SPEC §13.4). The
    /// answer is kept in `decision_answer`, and the item moves to the next round with the answer as
    /// its approach and the chosen option's verdict: a `fix` stays open for that round's fixer, and an
    /// `answer` is handled with the option's `reply_body`, if any. A typed reply is an `answer` whose
    /// reply is the text.
    @discardableResult
    public func answerDecision(itemId: Int64, choice: PRDecisionChoice, now: Int64 = .nowMillis) throws -> PRItem {
        try db.writer.write { db in
            guard var item = try PRItem.fetchOne(db, key: itemId), item.isOpenDecision,
                  let watch = try PRWatch.fetchOne(db, key: item.watchId)
            else { throw PRVerdictRejection("Item \(itemId) is no longer an open decision.") }
            let answer: String
            switch choice {
            case .option(let label):
                guard let option = item.decisionOptions.first(where: { $0.label == label }) else {
                    throw PRVerdictRejection("Item \(itemId) has no option \"\(label)\".")
                }
                answer = option.label
                item.verdict = option.verdict
                item.replyBody = option.verdict == .answer ? option.replyBody : nil
            case .reply(let text):
                answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
                item.verdict = .answer
                item.replyBody = answer
            }
            guard !answer.isEmpty else { throw PRVerdictRejection("The answer is empty.") }
            guard item.verdict == .fix || item.verdict == .answer else {
                throw PRVerdictRejection("Item \(itemId)'s option \"\(answer)\" is neither a fix nor an answer.")
            }
            item.decisionAnswer = answer
            item.approach = answer
            item.round = watch.round + 1
            _ = try Self.applyVerdict(db, to: &item, watch: watch, now: now)
            item.updatedAt = now
            try item.update(db)
            return item
        }
    }
}
