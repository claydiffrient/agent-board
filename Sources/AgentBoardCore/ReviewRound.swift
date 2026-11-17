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

    /// A `review_finding` ruling's `finding_ref`: the round's number and the finding's 1-based number (SPEC §15.2).
    public static func findingRef(round: Int, finding: Int) -> String { "\(round):\(finding)" }

    /// The findings of `round` whose newest standing ruling is `overrule`, keyed by finding number (SPEC §15.6).
    public static func overruled(_ db: Database, round: ReviewRound) throws -> [Int: Ruling] {
        var result: [Int: Ruling] = [:]
        for number in round.findings.indices.map({ $0 + 1 }) {
            let subject = RulingSubject.reviewFinding(
                taskId: round.taskId, ref: findingRef(round: round.number, finding: number)
            )
            if let newest = try RulingStore.standing(db, subject: subject).first, newest.verdict == .overrule {
                result[number] = newest
            }
        }
        return result
    }

    public static func overruled(in db: AppDatabase, round: ReviewRound) throws -> [Int: Ruling] {
        try db.reader.read { try overruled($0, round: round) }
    }

    /// SPEC §5.1: a verdict after an earlier round grades each of that round's findings exactly once,
    /// with evidence, except the ones a person overruled (§15.6), which it must leave out. Returns the
    /// grades in finding order.
    static func checkGrades(_ db: Database, _ grades: [GradedFinding], against previous: ReviewRound?) throws -> [GradedFinding] {
        let count = previous?.findings.count ?? 0
        let settled = try previous.map { try overruled(db, round: $0) } ?? [:]
        let numbers = grades.map(\.finding)
        if let unknown = numbers.first(where: { $0 < 1 || $0 > count }) {
            throw ReviewGradingRejection(reason: count == 0
                ? "There is no earlier finding to grade, but the verdict graded finding \(unknown). Leave grades out."
                : "Finding \(unknown) does not exist; the previous round had findings 1 to \(count).")
        }
        if let ruled = numbers.first(where: { settled[$0] != nil }) {
            throw ReviewGradingRejection(reason: "Finding \(ruled) was overruled by a person, so it is settled. "
                + "Leave it out of grades.")
        }
        if let repeated = Dictionary(grouping: numbers, by: { $0 }).first(where: { $0.value.count > 1 })?.key {
            throw ReviewGradingRejection(reason: "Finding \(repeated) is graded more than once.")
        }
        if let blank = grades.first(where: { $0.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            throw ReviewGradingRejection(reason: "Finding \(blank.finding)'s grade has no evidence.")
        }
        let missing = (0..<count).map { $0 + 1 }.filter { !numbers.contains($0) && settled[$0] == nil }
        guard let previous, !missing.isEmpty else { return grades.sorted { $0.finding < $1.finding } }
        throw ReviewGradingRejection(reason: "Round \(previous.number) left \(count) finding\(count == 1 ? "" : "s"), "
            + "and the verdict does not grade finding\(missing.count == 1 ? "" : "s") "
            + missing.map(String.init).joined(separator: ", ") + ". Grade every one that is not overruled.")
    }

    /// The previous-round finding numbers a reopen's finding cites as "finding N".
    static func citedFindings(_ finding: String) -> Set<Int> {
        guard let citation = try? NSRegularExpression(pattern: #"\bfinding\s+#?(\d+)\b"#, options: .caseInsensitive)
        else { return [] }
        let range = NSRange(finding.startIndex..., in: finding)
        return Set(citation.matches(in: finding, range: range).compactMap { match in
            Range(match.range(at: 1), in: finding).flatMap { Int(finding[$0]) }
        })
    }

    /// SPEC §15.6: a reopen whose every finding cites only overruled findings rests on nothing a person left open.
    static func checkReopen(_ findings: [String], overruled: [Int: Ruling], round: Int) throws {
        guard !overruled.isEmpty else { return }
        let cited = findings.map(citedFindings)
        guard cited.allSatisfy({ !$0.isEmpty && $0.isSubset(of: overruled.keys) }) else { return }
        let numbers = cited.reduce(into: Set<Int>()) { $0.formUnion($1) }.sorted().map(String.init)
        throw ReviewReopenRejection(reason: "Every finding names round \(round)'s finding"
            + "\(numbers.count == 1 ? "" : "s") \(numbers.joined(separator: ", ")), which a person overruled, so "
            + "\(numbers.count == 1 ? "it is" : "they are") settled and cannot reopen the task.")
    }
}

/// A reopen refused because its findings rest only on findings a person overruled (SPEC §15.6).
public struct ReviewReopenRejection: Error, Sendable, Equatable {
    public var reason: String
}

/// A verdict refused because it does not grade the previous round's findings as SPEC §5.1 requires.
public struct ReviewGradingRejection: Error, Sendable, Equatable {
    public var reason: String
}
