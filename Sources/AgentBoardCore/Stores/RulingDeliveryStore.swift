import Foundation
import GRDB

public enum RulingDeliveryVia: String, Codable, Sendable, Equatable, DatabaseValueConvertible {
    case resume
    case hook
}

/// The queue that carries a task ruling to the task's live sessions (SPEC §15.8). A row is queued when
/// the ruling is written and claimed exactly once, by whichever path reaches the session first.
public struct RulingDeliveryStore: Sendable {
    static let deliverable: Set<RulingVerdict> = [.proceed, .instead, .hold]
    /// `setup` is left out: its process has not launched, and its opening prompt reads the standing rulings.
    static let reachable: [SessionState] = [.starting, .running, .idle, .blocked, .waitingOnLock]
    /// States in which the session makes no further tool call, so only a resume reaches it.
    public static let resumable: [SessionState] = [.idle, .blocked]

    let db: AppDatabase

    public init(_ db: AppDatabase) {
        self.db = db
    }

    static func queue(_ db: Database, _ ruling: Ruling) throws {
        guard ruling.subjectKind == .task, deliverable.contains(ruling.verdict), let taskId = ruling.taskId else { return }
        try db.execute(
            sql: """
                INSERT INTO ruling_delivery (ruling_id, session_id)
                SELECT ?, session_id FROM agent_session
                WHERE task_id = ? AND role = ? AND state IN (\(databaseQuestionMarks(count: reachable.count)))
                """,
            arguments: [ruling.id, taskId, SessionRole.worker.rawValue] + StatementArguments(reachable.map(\.rawValue))
        )
    }

    /// The sessions owed a ruling that sit idle or blocked, each with its unclaimed rulings, newest first.
    /// A session blocked on a Claude Code prompt is left out: only the terminal answers that prompt, so its
    /// rulings wait for its next `PostToolUse`.
    public func owedByResume() throws -> [(session: AgentSession, rulings: [Ruling])] {
        try db.reader.read { db in
            let sessions = try AgentSession.fetchAll(
                db,
                sql: """
                    SELECT s.* FROM agent_session s
                    WHERE s.state IN (\(databaseQuestionMarks(count: Self.resumable.count)))
                      AND EXISTS (SELECT 1 FROM ruling_delivery d WHERE d.session_id = s.session_id AND d.delivered_at IS NULL)
                      AND NOT (s.state = ? AND EXISTS (SELECT 1 FROM task t WHERE t.id = s.task_id
                                                       AND t.blocked_source = ?))
                    """,
                arguments: StatementArguments(Self.resumable.map(\.rawValue))
                    + [SessionState.blocked.rawValue, BlockedSource.prompt.rawValue]
            )
            return try sessions.map { ($0, try Self.unclaimed(db, sessionId: $0.sessionId)) }
        }
    }

    /// Claims every ruling still owed to the session and returns them, newest first. Empty when another
    /// path claimed them first.
    public func claim(sessionId: String, via: RulingDeliveryVia, at: Int64 = .nowMillis) throws -> [Ruling] {
        try db.writer.write { db in
            let owed = try Self.unclaimed(db, sessionId: sessionId)
            guard !owed.isEmpty else { return [] }
            try db.execute(
                sql: """
                    UPDATE ruling_delivery SET delivered_at = ?, delivered_via = ?
                    WHERE session_id = ? AND delivered_at IS NULL
                      AND ruling_id IN (\(databaseQuestionMarks(count: owed.count)))
                    """,
                arguments: [at, via.rawValue, sessionId] + StatementArguments(owed.map(\.id))
            )
            return owed
        }
    }

    /// Undoes a resume claim whose resume never ran, so the next hook or tick can carry the rulings.
    public func release(sessionId: String, rulingIds: [String]) throws {
        guard !rulingIds.isEmpty else { return }
        try db.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE ruling_delivery SET delivered_at = NULL, delivered_via = NULL
                    WHERE session_id = ? AND ruling_id IN (\(databaseQuestionMarks(count: rulingIds.count)))
                    """,
                arguments: [sessionId] + StatementArguments(rulingIds)
            )
        }
    }

    /// Drops what an ended session was still owed; its rulings reach the next run through its prompt.
    public func dropOwed(sessionId: String) throws {
        try db.writer.write { db in
            try db.execute(
                sql: "DELETE FROM ruling_delivery WHERE session_id = ? AND delivered_at IS NULL",
                arguments: [sessionId]
            )
        }
    }

    public func deliveredVia(rulingId: String, sessionId: String) throws -> RulingDeliveryVia? {
        try db.reader.read { db in
            try RulingDeliveryVia.fetchOne(
                db, sql: "SELECT delivered_via FROM ruling_delivery WHERE ruling_id = ? AND session_id = ?",
                arguments: [rulingId, sessionId]
            )
        }
    }

    static func moveOwed(_ db: Database, from priorId: String, to sessionId: String) throws {
        try db.execute(
            sql: "UPDATE ruling_delivery SET session_id = ? WHERE session_id = ? AND delivered_at IS NULL",
            arguments: [sessionId, priorId]
        )
    }

    private static func unclaimed(_ db: Database, sessionId: String) throws -> [Ruling] {
        try Ruling.fetchAll(
            db,
            sql: """
                SELECT r.* FROM ruling r JOIN ruling_delivery d ON d.ruling_id = r.id
                WHERE d.session_id = ? AND d.delivered_at IS NULL
                ORDER BY r.answered_at DESC, r.rowid DESC
                """,
            arguments: [sessionId]
        )
    }
}

/// The app-authored text that carries a ruling into a live session (SPEC §15.8).
public enum RulingDelivery {
    /// Fits the hook's injected-text limit: the questions go first, then the text is cut short.
    public static func context(_ rulings: [Ruling], limit: Int = OpeningPrompt.briefCharacterBudget) -> String {
        let lead = "While you were working, the human answered a question about this task in Agent Board."
        let full = section(rulings, lead: lead)
        if full.count <= limit { return full }
        let bare = section(rulings, lead: lead, withQuestions: false)
        if bare.count <= limit { return bare }
        let suffix = "\n… [cut short at the hook's limit]"
        return String(bare.prefix(limit - suffix.count)) + suffix
    }

    public static func resumePrompt(_ rulings: [Ruling]) -> String {
        section(
            rulings,
            lead: "Agent Board resumed this session because the human answered a question about this task."
        ) + (rulings.first?.verdict == .hold ? "" : "\n\nWhen finished: do not push, and call `report_complete`.")
    }

    public static func progressText(_ rulings: [Ruling], via: RulingDeliveryVia) -> String {
        let verdicts = rulings.map { "`\($0.verdict.rawValue)`" }.joined(separator: ", ")
        let what = rulings.count == 1 ? "the human's ruling \(verdicts)" : "the human's rulings \(verdicts)"
        return switch via {
        case .hook: "Delivered \(what) to the running session."
        case .resume: "Delivered \(what) to the session by resuming it."
        }
    }

    private static func section(_ rulings: [Ruling], lead: String, withQuestions: Bool = true) -> String {
        let entries = withQuestions ? rulings.map(OpeningPrompt.rulingEntry) : rulings.map { "- \($0.quoted)" }
        return """
        # The human ruled on your task
        \(lead) A ruling outranks your own judgment, the task body, any comment, and any reviewer finding.

        \(entries.joined(separator: "\n"))

        \(rulings.map { instruction($0.verdict) }.first ?? "")
        """
    }

    private static func instruction(_ verdict: RulingVerdict) -> String {
        switch verdict {
        case .hold:
            "Stop work on this task now: make no further changes and end your turn. The task stays blocked "
                + "until the human rules again."
        case .instead:
            "Do what the note says instead of what you proposed, then continue the task."
        default:
            "Continue the task as you proposed."
        }
    }
}
