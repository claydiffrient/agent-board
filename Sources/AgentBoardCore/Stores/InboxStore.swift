import Foundation
import GRDB

/// The surfaces whose open question waits on the human (SPEC §15.5).
public enum InboxItemKind: String, Codable, Sendable, CaseIterable, Equatable {
    case approval
    /// Blocked by `report_blocked` or by a Claude Code prompt; both go through `Board.block`.
    case blockedTask = "blocked_task"
    /// In `review` with no rostered reviewer: human routing, protected paths, or a reviewer that refused it.
    case humanReview = "human_review"
    /// In `review` under a rostered reviewer whose session ended its turn without a verdict.
    case reviewerStopped = "reviewer_stopped"
    case proposal
    case prDecision = "pr_decision"
    case parkedWatch = "parked_watch"
}

public struct InboxItem: Sendable, Equatable, Identifiable {
    public var kind: InboxItemKind
    public var projectId: String
    /// The task, approval, PR item or watch id.
    public var subjectId: String
    public var title: String
    /// The asker's text, shown as quoted data: a block reason, an approval reason, a decision question.
    public var question: String?
    /// The episode stamp a ruling on this row records as `question_at` (SPEC §15.1); 0 for a row from before
    /// the stamp existed.
    public var questionAt: Int64

    public var id: String { "\(kind.rawValue):\(subjectId)" }

    /// What a ruling on this row is scoped to; nil for a proposal, which takes no ruling.
    public var subject: RulingSubject? {
        switch kind {
        case .approval: .approval(subjectId)
        case .blockedTask, .humanReview, .reviewerStopped: .task(subjectId)
        case .proposal: nil
        case .prDecision: Int64(subjectId).map(RulingSubject.prItem)
        case .parkedWatch: .prWatch(subjectId)
        }
    }
}

/// Every question waiting on the human, across projects: each surface's open-question predicate minus the
/// rows a ruling has answered for the current episode (SPEC §15.5). The badge and the page read the same rows.
public struct InboxStore: Sendable {
    let db: AppDatabase

    public init(_ db: AppDatabase) {
        self.db = db
    }

    public func items(projectId: String? = nil) throws -> [InboxItem] {
        try db.reader.read { db in try Self.items(db, projectId: projectId) }
    }

    public func count(projectId: String? = nil) throws -> Int {
        try items(projectId: projectId).count
    }

    public func observe(projectId: String? = nil) -> ValueObservation<ValueReducers.Fetch<[InboxItem]>> {
        ValueObservation.tracking { db in try Self.items(db, projectId: projectId) }
    }

    public func observeCount(projectId: String? = nil) -> ValueObservation<ValueReducers.Fetch<Int>> {
        ValueObservation.tracking { db in try Self.items(db, projectId: projectId).count }
    }

    static func items(_ db: Database, projectId: String?) throws -> [InboxItem] {
        try Row.fetchAll(db, sql: sql, arguments: [projectId, projectId]).map { row in
            InboxItem(
                kind: InboxItemKind(rawValue: row["kind"])!,
                projectId: row["project_id"],
                subjectId: row["subject_id"],
                title: row["title"],
                question: row["question"],
                questionAt: row["question_at"]
            )
        }
    }

    private static func unruled(_ kind: RulingSubjectKind, _ column: String, _ subject: String, _ episode: String) -> String {
        """
        NOT EXISTS (SELECT 1 FROM ruling r WHERE r.subject_kind = '\(kind.rawValue)' AND r.\(column) = \(subject)
                    AND r.question_at >= \(episode))
        """
    }

    /// A reviewer counts as stopped once it is the task's newest session and its turn has ended, the line
    /// `ReviewHold` draws; before the reviewer starts, the newest session is still the completed worker.
    private static let stoppedReviewerAt = """
        (SELECT s.started_at FROM agent_session s
         WHERE s.task_id = t.id AND s.roster_agent_id = t.reviewer_agent_id
           AND (s.state = '\(SessionState.idle.rawValue)' OR s.state NOT IN (\(SessionStore.activeStatesSQL)))
           AND NOT EXISTS (SELECT 1 FROM agent_session n WHERE n.task_id = t.id AND n.started_at > s.started_at))
        """

    /// PR rows follow the attention badge's rule: follow-through on, and for a decision, a watch not paused.
    static let sql = """
        SELECT * FROM (
          SELECT '\(InboxItemKind.approval.rawValue)' AS kind, a.project_id, a.id AS subject_id,
                 a.kind AS title, a.reason AS question, a.created_at AS question_at
          FROM approval a
          WHERE a.resolved_at IS NULL
            AND NOT EXISTS (SELECT 1 FROM ruling r WHERE r.subject_kind = 'approval' AND r.approval_id = a.id)

          UNION ALL
          SELECT '\(InboxItemKind.blockedTask.rawValue)', t.project_id, t.id, t.title, t.blocked_reason,
                 COALESCE(t.blocked_at, 0)
          FROM task t
          WHERE t.blocked = 1 AND t.archived_at IS NULL
            AND \(unruled(.task, "task_id", "t.id", "COALESCE(t.blocked_at, 0)"))

          UNION ALL
          SELECT '\(InboxItemKind.humanReview.rawValue)', t.project_id, t.id, t.title, t.human_review_reason,
                 COALESCE(t.review_entered_at, 0)
          FROM task t
          WHERE t.column_name = '\(TaskColumn.review.rawValue)' AND t.reviewer_agent_id IS NULL
            AND t.blocked = 0 AND t.archived_at IS NULL
            AND \(unruled(.task, "task_id", "t.id", "COALESCE(t.review_entered_at, 0)"))

          UNION ALL
          SELECT * FROM (
            SELECT '\(InboxItemKind.reviewerStopped.rawValue)' AS kind, t.project_id, t.id AS subject_id, t.title,
                   NULL AS question, \(stoppedReviewerAt) AS question_at
            FROM task t
            WHERE t.column_name = '\(TaskColumn.review.rawValue)' AND t.reviewer_agent_id IS NOT NULL
              AND t.blocked = 0 AND t.archived_at IS NULL
          ) st
          WHERE st.question_at IS NOT NULL
            AND \(unruled(.task, "task_id", "st.subject_id", "st.question_at"))

          UNION ALL
          SELECT '\(InboxItemKind.proposal.rawValue)', t.project_id, t.id, t.title, NULL, t.created_at
          FROM task t JOIN project p ON p.id = t.project_id
          WHERE t.column_name = '\(TaskColumn.proposed.rawValue)' AND t.archived_at IS NULL
            AND COALESCE(json_extract(p.settings_json, '$.autonomyEnabled'), 0) = 0

          UNION ALL
          SELECT '\(InboxItemKind.prDecision.rawValue)', w.project_id, CAST(i.id AS TEXT),
                 '#' || w.number || ' ' || w.title, i.decision_question,
                 COALESCE(i.decision_notified_at, i.created_at)
          FROM pr_item i JOIN pr_watch w ON w.id = i.watch_id JOIN project p ON p.id = w.project_id
          WHERE i.state = 'open' AND i.verdict = 'decision' AND w.state NOT IN ('merged', 'closed', 'stopped')
            AND \(PRWatchStore.countsTowardAttention)
            AND \(unruled(.prItem, "pr_item_id", "i.id", "COALESCE(i.decision_notified_at, i.created_at)"))

          UNION ALL
          SELECT '\(InboxItemKind.parkedWatch.rawValue)', w.project_id, w.id, '#' || w.number || ' ' || w.title,
                 w.parked_reason, COALESCE(w.parked_at, 0)
          FROM pr_watch w JOIN project p ON p.id = w.project_id
          WHERE w.state = 'parked' AND json_extract(p.settings_json, '$.prFollowThrough.enabled') = 1
            AND \(unruled(.prWatch, "pr_watch_id", "w.id", "COALESCE(w.parked_at, 0)"))
        )
        WHERE ? IS NULL OR project_id = ?
        ORDER BY question_at, kind, subject_id
        """
}
