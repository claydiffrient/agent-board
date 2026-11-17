import Foundation
import GRDB

/// How a re-review grades one finding of the round before it (SPEC §5.1).
public enum FindingGrade: String, Codable, Sendable, CaseIterable {
    case fixed
    case partlyFixed = "partly_fixed"
    case notFixed = "not_fixed"
    case moot
}

/// `finding` is the 1-based number the previous round's finding carries in the reviewer's prompt.
public struct GradedFinding: Codable, Sendable, Equatable {
    public var finding: Int
    public var grade: FindingGrade
    public var evidence: String

    public init(finding: Int, grade: FindingGrade, evidence: String) {
        self.finding = finding
        self.grade = grade
        self.evidence = evidence
    }
}

public enum ReviewRoundOutcome: String, Codable, Sendable {
    case accepted
    case reopened
    /// A reopen that was the project's `reviewRoundCap`-th round: the task stayed in `review` (SPEC §5).
    case capped
}

/// One rostered reviewer's verdict on an ordinary task (SPEC §4, §5.1). Fix rounds (§13) keep their own record.
public struct ReviewRound: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "review_round"

    public var id: Int64?
    public var taskId: String
    public var number: Int
    public var sessionId: String?
    public var reviewerName: String
    public var outcome: ReviewRoundOutcome
    /// Empty for an acceptance.
    public var findings: [String]
    public var verdict: String?
    /// How this round graded the previous round's findings.
    public var grades: [GradedFinding]
    /// The commit the reviewer was spawned on; the next round reads `git diff <reviewedHead>..HEAD` first.
    public var reviewedHead: String?
    public var at: Int64

    public enum CodingKeys: String, CodingKey {
        case id
        case taskId = "task_id"
        case number
        case sessionId = "session_id"
        case reviewerName = "reviewer_name"
        case outcome
        case findings
        case verdict
        case grades
        case reviewedHead = "reviewed_head"
        case at
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static func latest(_ db: Database, taskId: String) throws -> ReviewRound? {
        try ReviewRound.fetchOne(
            db, sql: "SELECT * FROM review_round WHERE task_id = ? ORDER BY number DESC LIMIT 1", arguments: [taskId]
        )
    }

    public static func latest(in db: AppDatabase, taskId: String) throws -> ReviewRound? {
        try db.reader.read { try latest($0, taskId: taskId) }
    }

    public static func all(in db: AppDatabase, taskId: String) throws -> [ReviewRound] {
        try db.reader.read {
            try ReviewRound.fetchAll(
                $0, sql: "SELECT * FROM review_round WHERE task_id = ? ORDER BY number", arguments: [taskId]
            )
        }
    }

    /// Findings as the next worker and the next reviewer read them: one verbatim, several numbered.
    public static func renderFindings(_ findings: [String]) -> String {
        guard findings.count > 1 else { return findings.first ?? "" }
        return findings.enumerated().map { "Finding \($0.offset + 1): \($0.element)" }.joined(separator: "\n\n")
    }

    public static func renderGrades(_ grades: [GradedFinding], ofRound number: Int) -> String {
        (["Grades of round \(number)'s findings:"]
            + grades.map { "- Finding \($0.finding): \($0.grade.rawValue). \($0.evidence)" })
            .joined(separator: "\n")
    }

    /// SPEC §5.1: a verdict after an earlier round grades each of that round's findings exactly once,
    /// with evidence. Returns the grades in finding order.
    static func checkGrades(_ grades: [GradedFinding], against previous: ReviewRound?) throws -> [GradedFinding] {
        let count = previous?.findings.count ?? 0
        let numbers = grades.map(\.finding)
        if let unknown = numbers.first(where: { $0 < 1 || $0 > count }) {
            throw ReviewGradingRejection(reason: count == 0
                ? "There is no earlier finding to grade, but the verdict graded finding \(unknown). Leave grades out."
                : "Finding \(unknown) does not exist; the previous round had findings 1 to \(count).")
        }
        if let repeated = Dictionary(grouping: numbers, by: { $0 }).first(where: { $0.value.count > 1 })?.key {
            throw ReviewGradingRejection(reason: "Finding \(repeated) is graded more than once.")
        }
        if let blank = grades.first(where: { $0.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            throw ReviewGradingRejection(reason: "Finding \(blank.finding)'s grade has no evidence.")
        }
        let missing = (0..<count).map { $0 + 1 }.filter { !numbers.contains($0) }
        guard let previous, !missing.isEmpty else { return grades.sorted { $0.finding < $1.finding } }
        throw ReviewGradingRejection(reason: "Round \(previous.number) left \(count) finding\(count == 1 ? "" : "s"), "
            + "and the verdict does not grade finding\(missing.count == 1 ? "" : "s") "
            + missing.map(String.init).joined(separator: ", ") + ". Grade every one of them.")
    }
}

/// A verdict refused because it does not grade the previous round's findings as SPEC §5.1 requires.
public struct ReviewGradingRejection: Error, Sendable, Equatable {
    public var reason: String
}
