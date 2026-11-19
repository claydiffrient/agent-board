import Foundation
import GRDB

/// The `ruling` report queued for the orchestrator when the human rules (SPEC §9.1). The first line is
/// app-authored and names the ruling's id, which is how `list_reports` finds the row to render; the
/// human's note follows between markers, as a `comment` report quotes a comment.
public enum RulingReport {
    static let idPrefix = "Ruling "

    static func queue(_ db: Database, _ ruling: Ruling) throws {
        _ = try ReportStore.insert(
            db, projectId: ruling.projectId, taskId: try taskId(db, ruling), sessionId: nil, kind: .ruling,
            body: try body(db, ruling)
        )
    }

    /// The ruling id a `ruling` report's body names, nil for any other body.
    public static func rulingId(in body: String) -> String? {
        guard let first = body.split(separator: "\n", maxSplits: 1).first, first.hasPrefix(idPrefix),
              let colon = first.firstIndex(of: ":")
        else { return nil }
        let id = first[first.index(first.startIndex, offsetBy: idPrefix.count)..<colon]
        return id.isEmpty ? nil : String(id)
    }

    /// The id a ruling's subject goes by in tool results: a task, approval, PR item or watch id.
    public static func subjectId(_ ruling: Ruling) -> String? {
        switch ruling.subjectKind {
        case .task, .reviewFinding: ruling.taskId
        case .approval: ruling.approvalId
        case .prItem: ruling.prItemId.map(String.init)
        case .prWatch: ruling.prWatchId
        }
    }

    static func body(_ db: Database, _ ruling: Ruling) throws -> String {
        var line = "\(idPrefix)\(ruling.id): the human ruled `\(ruling.verdict.rawValue)`"
        if let choice = ruling.choice { line += " (\(choice))" }
        line += " on \(try subject(db, ruling))."
        if let supersedes = ruling.supersedes { line += " It supersedes ruling \(supersedes)." }
        guard let note = ruling.note else { return line }
        return """
        \(line)
        --- note begins ---
        \(note)
        --- note ends ---
        """
    }

    private static func subject(_ db: Database, _ ruling: Ruling) throws -> String {
        switch ruling.subjectKind {
        case .task:
            return try ruling.taskId.map { try taskLabel(db, $0) } ?? "a task"
        case .reviewFinding:
            return "finding \(ruling.findingRef ?? "?") of \(try ruling.taskId.map { try taskLabel(db, $0) } ?? "a task")"
        case .approval:
            guard let id = ruling.approvalId, let approval = try Approval.fetchOne(db, key: id) else {
                return "approval \(ruling.approvalId ?? "?")"
            }
            var text = "approval \(id) (\(approval.kind.rawValue)"
            if let taskId = approval.taskId { text += " for \(try taskLabel(db, taskId))" }
            else if let epicId = approval.epicId { text += " for epic \(epicId)" }
            return text + ")"
        case .prItem:
            let number = try ruling.prItemId.flatMap {
                try Int.fetchOne(
                    db, sql: "SELECT w.number FROM pr_item i JOIN pr_watch w ON w.id = i.watch_id WHERE i.id = ?",
                    arguments: [$0]
                )
            }
            return "item \(ruling.prItemId.map(String.init) ?? "?")" + (number.map { " of pull request #\($0)" } ?? "")
        case .prWatch:
            let number = try ruling.prWatchId.flatMap {
                try Int.fetchOne(db, sql: "SELECT number FROM pr_watch WHERE id = ?", arguments: [$0])
            }
            return "watch \(ruling.prWatchId ?? "?")" + (number.map { " on pull request #\($0)" } ?? "")
        }
    }

    private static func taskLabel(_ db: Database, _ id: String) throws -> String {
        let title = try String.fetchOne(db, sql: "SELECT title FROM task WHERE id = ?", arguments: [id])
        return "task \(id)" + (title.map { " \"\($0)\"" } ?? "")
    }

    private static func taskId(_ db: Database, _ ruling: Ruling) throws -> String? {
        if let taskId = ruling.taskId { return taskId }
        guard let approvalId = ruling.approvalId else { return nil }
        return try String.fetchOne(db, sql: "SELECT task_id FROM approval WHERE id = ?", arguments: [approvalId])
    }
}
