import Foundation
import GRDB

public enum RulingSubjectKind: String, Codable, Sendable, CaseIterable, Equatable, DatabaseValueConvertible {
    case task
    case approval
    case prItem = "pr_item"
    case prWatch = "pr_watch"
    case reviewFinding = "review_finding"

    /// The verdicts a ruling on this kind of subject may carry (SPEC §15.2).
    public var verdicts: Set<RulingVerdict> {
        switch self {
        case .task: [.proceed, .instead, .hold, .reopen]
        case .approval: [.deny]
        case .prItem: [.choose, .reply, .dismiss]
        case .prWatch: [.keepParked]
        case .reviewFinding: [.overrule, .uphold]
        }
    }
}

/// The closed set of answers a human can give (SPEC §15.2). `dismiss` exists for the PR item dismissals
/// the `ruling` migration carried over.
public enum RulingVerdict: String, Codable, Sendable, CaseIterable, Equatable, DatabaseValueConvertible {
    case proceed
    case instead
    case hold
    case deny
    case reopen
    case overrule
    case uphold
    case choose
    case reply
    case keepParked = "keep_parked"
    case dismiss

    public var requiresNote: Bool {
        [.instead, .hold, .deny, .reopen, .overrule, .dismiss].contains(self)
    }
}

public enum RulingSubject: Sendable, Equatable, Hashable {
    case task(String)
    case approval(String)
    case prItem(Int64)
    case prWatch(String)
    /// `ref` is `"<review_round.number>:<index>"` on the task.
    case reviewFinding(taskId: String, ref: String)

    public var kind: RulingSubjectKind {
        switch self {
        case .task: .task
        case .approval: .approval
        case .prItem: .prItem
        case .prWatch: .prWatch
        case .reviewFinding: .reviewFinding
        }
    }
}

/// One answer the human gave to one asking (SPEC §15). Append-only: nothing updates a row, and only
/// the app's UI writes one.
public struct Ruling: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
    public static let databaseTableName = "ruling"

    public var id: String
    public var projectId: String
    public var subjectKind: RulingSubjectKind
    public var taskId: String?
    public var approvalId: String?
    public var prItemId: Int64?
    public var prWatchId: String?
    public var findingRef: String?
    /// What the human was shown, as it read when they answered.
    public var question: String
    /// The episode stamp of the asking this answers (SPEC §15.1).
    public var questionAt: Int64
    public var verdict: RulingVerdict
    public var choice: String?
    public var note: String?
    public var supersedes: String?
    public var answeredAt: Int64

    public enum CodingKeys: String, CodingKey {
        case id
        case projectId = "project_id"
        case subjectKind = "subject_kind"
        case taskId = "task_id"
        case approvalId = "approval_id"
        case prItemId = "pr_item_id"
        case prWatchId = "pr_watch_id"
        case findingRef = "finding_ref"
        case question
        case questionAt = "question_at"
        case verdict
        case choice
        case note
        case supersedes
        case answeredAt = "answered_at"
    }

    public var subject: RulingSubject? {
        switch subjectKind {
        case .task: taskId.map(RulingSubject.task)
        case .approval: approvalId.map(RulingSubject.approval)
        case .prItem: prItemId.map(RulingSubject.prItem)
        case .prWatch: prWatchId.map(RulingSubject.prWatch)
        case .reviewFinding:
            taskId.flatMap { task in findingRef.map { .reviewFinding(taskId: task, ref: $0) } }
        }
    }
}

public enum RulingError: Error, Equatable, LocalizedError {
    case subjectNotFound(RulingSubject)
    case verdictNotForSubject(RulingVerdict, RulingSubjectKind)
    case noteRequired(RulingVerdict)
    case noteTooLong(limit: Int)
    case choiceRequired
    case choiceNotAllowed(RulingVerdict)
    case emptyQuestion
    case supersededNotFound(String)
    case supersedesAnotherSubject(String)
    case alreadySuperseded(String)

    public var errorDescription: String? {
        switch self {
        case .subjectNotFound(let subject): "Nothing to rule on: \(subject) does not exist."
        case .verdictNotForSubject(let verdict, let kind): "A \(kind.rawValue) cannot be ruled \(verdict.rawValue)."
        case .noteRequired(let verdict): "A \(verdict.rawValue) ruling needs a note."
        case .noteTooLong(let limit): "A ruling's note is limited to \(limit) characters."
        case .choiceRequired: "A choose ruling needs the chosen option."
        case .choiceNotAllowed(let verdict): "A \(verdict.rawValue) ruling takes no choice."
        case .emptyQuestion: "A ruling needs the question it answers."
        case .supersededNotFound(let id): "Ruling \(id) does not exist."
        case .supersedesAnotherSubject(let id): "Ruling \(id) is on a different subject."
        case .alreadySuperseded(let id): "Ruling \(id) has already been superseded."
        }
    }
}

/// A request the board refused because a standing ruling forbids it (SPEC §15.6). The reason quotes
/// the ruling, so an orchestrator reads the human's words rather than a bare refusal.
public struct RulingRefusal: LocalizedError, Sendable, Equatable {
    public var ruling: Ruling
    public var reason: String

    public init(_ ruling: Ruling, _ reason: String) {
        self.ruling = ruling
        self.reason = reason
    }

    public var errorDescription: String? { reason }
}

extension Ruling {
    /// `verdict` with the human's note, for refusal text and prompts.
    public var quoted: String {
        let when = Date(timeIntervalSince1970: TimeInterval(answeredAt) / 1000)
            .formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
        var text = "`\(verdict.rawValue)`"
        if let choice { text += " (\(choice))" }
        text += ", ruled \(when) UTC"
        if let note { text += ": \"\(note)\"" }
        return text
    }
}
