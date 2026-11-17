import Foundation
import GRDB

/// The only writer of `ruling` (SPEC §15). Called from the app's UI; no MCP handler may call `record`.
public struct RulingStore: Sendable {
    public static let noteLimit = 10_000

    let db: AppDatabase

    public init(_ db: AppDatabase) {
        self.db = db
    }

    @discardableResult
    public func record(
        _ subject: RulingSubject, question: String, questionAt: Int64, verdict: RulingVerdict,
        choice: String? = nil, note: String? = nil, supersedes: String? = nil, now: Int64 = .nowMillis
    ) throws -> Ruling {
        try db.writer.write { db in
            try Self.record(
                db, subject, question: question, questionAt: questionAt, verdict: verdict,
                choice: choice, note: note, supersedes: supersedes, now: now
            )
        }
    }

    static func record(
        _ db: Database, _ subject: RulingSubject, question: String, questionAt: Int64, verdict: RulingVerdict,
        choice: String?, note: String?, supersedes: String?, now: Int64
    ) throws -> Ruling {
        guard subject.kind.verdicts.contains(verdict) else {
            throw RulingError.verdictNotForSubject(verdict, subject.kind)
        }
        let note = note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if verdict.requiresNote, note == nil { throw RulingError.noteRequired(verdict) }
        if let note, note.count > noteLimit { throw RulingError.noteTooLong(limit: noteLimit) }
        let choice = choice?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if verdict == .choose, choice == nil { throw RulingError.choiceRequired }
        if verdict != .choose, choice != nil { throw RulingError.choiceNotAllowed(verdict) }
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { throw RulingError.emptyQuestion }
        guard let projectId = try projectId(db, of: subject) else { throw RulingError.subjectNotFound(subject) }
        if let supersedes {
            guard let prior = try Ruling.fetchOne(db, key: supersedes) else {
                throw RulingError.supersededNotFound(supersedes)
            }
            guard prior.subject == subject else { throw RulingError.supersedesAnotherSubject(supersedes) }
            guard try Ruling.filter(Column("supersedes") == supersedes).fetchCount(db) == 0 else {
                throw RulingError.alreadySuperseded(supersedes)
            }
        }

        var ruling = Ruling(
            id: BoardId.new(), projectId: projectId, subjectKind: subject.kind, question: question,
            questionAt: questionAt, verdict: verdict, choice: choice, note: note, supersedes: supersedes,
            answeredAt: now
        )
        switch subject {
        case .task(let id): ruling.taskId = id
        case .approval(let id): ruling.approvalId = id
        case .prItem(let id): ruling.prItemId = id
        case .prWatch(let id): ruling.prWatchId = id
        case .reviewFinding(let taskId, let ref):
            ruling.taskId = taskId
            ruling.findingRef = ref
        }
        try ruling.insert(db)
        return ruling
    }

    /// The subject's rulings that no later ruling supersedes, newest first (SPEC §15.3).
    public func standing(_ subject: RulingSubject) throws -> [Ruling] {
        try db.reader.read { db in try Self.standing(db, subject: subject) }
    }

    static func standing(_ db: Database, subject: RulingSubject) throws -> [Ruling] {
        try rulings(db, subject: subject, extra: "AND NOT EXISTS (SELECT 1 FROM ruling s WHERE s.supersedes = r.id)")
    }

    /// Every ruling on the subject, superseded or not, newest first.
    public func history(_ subject: RulingSubject) throws -> [Ruling] {
        try db.reader.read { db in try Self.history(db, subject: subject) }
    }

    static func history(_ db: Database, subject: RulingSubject) throws -> [Ruling] {
        try rulings(db, subject: subject, extra: "")
    }

    /// The standing `hold` that covers the task's current block, nil when none does (SPEC §15.5).
    public func holdInForce(taskId: String) throws -> Ruling? {
        try db.reader.read { db in
            try Task.fetchOne(db, key: taskId).flatMap { try Self.holdInForce(db, task: $0) }
        }
    }

    static func holdInForce(_ db: Database, task: Task) throws -> Ruling? {
        guard task.blocked else { return nil }
        let since = task.blockedAt ?? 0
        return try standing(db, subject: .task(task.id)).first { $0.verdict == .hold && $0.questionAt >= since }
    }

    /// The standing `keep_parked` that covers the watch's current parking, nil when none does.
    static func keepParkedInForce(_ db: Database, watch: PRWatch) throws -> Ruling? {
        guard watch.state == .parked else { return nil }
        let since = watch.parkedAt ?? 0
        return try standing(db, subject: .prWatch(watch.id)).first { $0.verdict == .keepParked && $0.questionAt >= since }
    }

    /// The project's denied approvals of `kind` whose `deny` ruling stands, newest ruling first.
    static func standingDenials(
        _ db: Database, projectId: String, kind: ApprovalKind
    ) throws -> [(approval: Approval, ruling: Ruling)] {
        let rulings = try Ruling.fetchAll(
            db,
            sql: """
            SELECT r.* FROM ruling r JOIN approval a ON a.id = r.approval_id
            WHERE r.subject_kind = 'approval' AND r.verdict = 'deny' AND a.project_id = ? AND a.kind = ?
              AND NOT EXISTS (SELECT 1 FROM ruling s WHERE s.supersedes = r.id)
            ORDER BY r.answered_at DESC, r.rowid DESC
            """,
            arguments: [projectId, kind.rawValue]
        )
        return try rulings.compactMap { ruling in
            try ruling.approvalId.flatMap { try Approval.fetchOne(db, key: $0) }.map { ($0, ruling) }
        }
    }

    private static func rulings(_ db: Database, subject: RulingSubject, extra: String) throws -> [Ruling] {
        let (filter, arguments) = where_(subject)
        return try Ruling.fetchAll(
            db,
            sql: "SELECT r.* FROM ruling r WHERE r.subject_kind = ? AND \(filter) \(extra) ORDER BY r.answered_at DESC, r.rowid DESC",
            arguments: [subject.kind.rawValue] + arguments
        )
    }

    private static func where_(_ subject: RulingSubject) -> (String, StatementArguments) {
        switch subject {
        case .task(let id): ("r.task_id = ?", [id])
        case .approval(let id): ("r.approval_id = ?", [id])
        case .prItem(let id): ("r.pr_item_id = ?", [id])
        case .prWatch(let id): ("r.pr_watch_id = ?", [id])
        case .reviewFinding(let taskId, let ref): ("r.task_id = ? AND r.finding_ref = ?", [taskId, ref])
        }
    }

    private static func projectId(_ db: Database, of subject: RulingSubject) throws -> String? {
        switch subject {
        case .task(let id), .reviewFinding(let id, _):
            try String.fetchOne(db, sql: "SELECT project_id FROM task WHERE id = ?", arguments: [id])
        case .approval(let id):
            try String.fetchOne(db, sql: "SELECT project_id FROM approval WHERE id = ?", arguments: [id])
        case .prItem(let id):
            try String.fetchOne(
                db,
                sql: "SELECT w.project_id FROM pr_item i JOIN pr_watch w ON w.id = i.watch_id WHERE i.id = ?",
                arguments: [id]
            )
        case .prWatch(let id):
            try String.fetchOne(db, sql: "SELECT project_id FROM pr_watch WHERE id = ?", arguments: [id])
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
