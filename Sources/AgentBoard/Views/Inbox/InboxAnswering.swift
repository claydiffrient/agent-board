import AgentBoardCore
import Foundation
import GRDB

/// A verdict an Inbox row offers in its Answer zone (SPEC §10, Inbox). Each writes a ruling and
/// nothing else, except `deny`, which resolves its approval as denied in the same write (SPEC §15.6).
enum InboxVerdict: Hashable, Identifiable {
    case proceed
    case instead
    case hold
    case deny
    case keepParked
    case choose(String)
    case reply
    case overrule(finding: Int)
    case uphold(finding: Int)

    var id: String {
        switch self {
        case .choose(let label): "choose:\(label)"
        case .overrule(let n): "overrule:\(n)"
        case .uphold(let n): "uphold:\(n)"
        default: title
        }
    }

    var title: String {
        switch self {
        case .proceed: "Proceed"
        case .instead: "Do this instead"
        case .hold: "Hold"
        case .deny: "Deny"
        case .keepParked: "Keep parked"
        case .choose(let label): label
        case .reply: "Reply with my note"
        case .overrule: "Overrule"
        case .uphold: "Uphold"
        }
    }

    var needsNote: Bool {
        switch self {
        case .instead, .hold, .deny, .reply, .overrule: true
        case .proceed, .keepParked, .choose, .uphold: false
        }
    }

    var help: String {
        switch self {
        case .proceed: "Tell the worker to go ahead as it proposed"
        case .instead: "Tell the worker to do what your note says instead"
        case .hold: "Keep the task blocked; no spawn or resume until it blocks again"
        case .deny: "Refuse this request; the same request is refused from now on"
        case .keepParked: "Leave the pull request parked; the orchestrator cannot resume it"
        case .choose: "Answer triage's question with this option"
        case .reply: "Answer with your note as the reply, owed until you post it"
        case .overrule: "Settle this finding: the next review must leave it out"
        case .uphold: "Agree with the reviewer on this finding"
        }
    }
}

/// What one Inbox row needs beyond the row itself, read once when it appears.
struct InboxRowContext: Equatable {
    var approval: Approval?
    var task: BoardTask?
    var session: AgentSession?
    var round: ReviewRound?
    /// The newest standing ruling on each finding of `round`, by 1-based number.
    var findingRulings: [Int: Ruling] = [:]
    var prItem: PRItem?
    var watch: PRWatch?
    var standing: [Ruling] = []

    static func load(_ db: AppDatabase, item: InboxItem) throws -> InboxRowContext {
        try db.reader.read { db in
            var context = InboxRowContext()
            if let subject = item.subject {
                context.standing = try RulingStore.standing(db, subject: subject)
            }
            switch item.kind {
            case .approval:
                context.approval = try Approval.fetchOne(db, key: item.subjectId)
                if let taskId = context.approval?.taskId { context.task = try Task.fetchOne(db, key: taskId) }
            case .blockedTask, .humanReview, .reviewerStopped, .proposal:
                context.task = try Task.fetchOne(db, key: item.subjectId)
                context.session = try AgentSession
                    .filter(Column("task_id") == item.subjectId)
                    .order(Column("started_at").desc)
                    .fetchOne(db)
                if item.kind == .humanReview, let round = try ReviewRound.latest(db, taskId: item.subjectId) {
                    context.round = round
                    for n in round.findings.indices.map({ $0 + 1 }) {
                        let subject = RulingSubject.reviewFinding(
                            taskId: item.subjectId, ref: ReviewRound.findingRef(round: round.number, finding: n)
                        )
                        context.findingRulings[n] = try RulingStore.standing(db, subject: subject).first
                    }
                }
            case .prDecision:
                context.prItem = try Int64(item.subjectId).flatMap { try PRItem.fetchOne(db, key: $0) }
                if let watchId = context.prItem?.watchId { context.watch = try PRWatch.fetchOne(db, key: watchId) }
            case .parkedWatch:
                context.watch = try PRWatch.fetchOne(db, key: item.subjectId)
            }
            return context
        }
    }

    /// The verdicts the row's Answer zone offers. A prompt block and a proposal take none, and a review
    /// held for a person takes them per finding of its latest round.
    func verdicts(for item: InboxItem) -> [InboxVerdict] {
        switch item.kind {
        case .blockedTask: item.blockedSource == .prompt ? [] : [.proceed, .instead, .hold]
        case .approval: [.deny]
        case .parkedWatch: [.keepParked]
        case .prDecision: (prItem?.decisionOptions ?? []).map { .choose($0.label) } + [.reply]
        case .humanReview, .reviewerStopped, .proposal: []
        }
    }

    var findings: [(number: Int, text: String)] {
        (round?.findings ?? []).enumerated().map { ($0.offset + 1, $0.element) }
    }
}

/// Writes an Inbox row's answer. The Answer zone's buttons call nothing else.
@MainActor
struct InboxAnswering {
    let db: AppDatabase
    let supervisor: any WorkerSupervising

    func answer(_ verdict: InboxVerdict, to item: InboxItem, context: InboxRowContext, note: String) async throws {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let rulings = RulingStore(db)
        let question = item.question?.nilIfBlank ?? item.title
        switch verdict {
        case .proceed, .instead, .hold:
            let ruled: RulingVerdict = verdict == .proceed ? .proceed : verdict == .instead ? .instead : .hold
            try rulings.record(
                .task(item.subjectId), question: question, questionAt: item.questionAt, verdict: ruled,
                note: note.nilIfBlank
            )
        case .deny:
            try await supervisor.deny(approvalId: item.subjectId, reason: note)
        case .keepParked:
            try rulings.record(
                .prWatch(item.subjectId), question: question, questionAt: item.questionAt, verdict: .keepParked,
                note: note.nilIfBlank
            )
        case .choose(let label):
            guard let id = Int64(item.subjectId) else { return }
            try await supervisor.answerPRDecision(itemId: id, choice: .option(label))
        case .reply:
            guard let id = Int64(item.subjectId) else { return }
            try await supervisor.answerPRDecision(itemId: id, choice: .reply(note))
        case .overrule(let n), .uphold(let n):
            guard let round = context.round, round.findings.indices.contains(n - 1) else { return }
            let isOverrule = if case .overrule = verdict { true } else { false }
            try rulings.record(
                .reviewFinding(taskId: item.subjectId, ref: ReviewRound.findingRef(round: round.number, finding: n)),
                question: round.findings[n - 1], questionAt: item.questionAt,
                verdict: isOverrule ? .overrule : .uphold, note: note.nilIfBlank
            )
        }
    }
}

extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
