import Foundation
import GRDB

/// Something a worktree removal could not do: a worktree kept, or a teardown hook that failed or
/// timed out. `taskId` is the task whose worktree it was, when the board still knows it.
public struct WorktreeCleanupFinding: Sendable, Equatable {
    public var taskId: String?
    public var text: String

    public init(taskId: String?, text: String) {
        self.taskId = taskId
        self.text = text
    }
}

extension Board {
    public static let worktreeCleanupLead = "Worktree cleanup:"

    /// SPEC §5: findings go on the task's progress and into the decision report for the removal —
    /// appended to `reportId` while the orchestrator has not read it, otherwise in one of their own.
    /// True when a report was written or changed.
    @discardableResult
    public func recordWorktreeCleanup(taskId: String, reportId: Int64?, findings: [String]) throws -> Bool {
        guard !findings.isEmpty else { return false }
        return try db.writer.write { db in
            guard let task = try Task.fetchOne(db, key: taskId) else { return false }
            let listed = findings.map { "- \($0)" }.joined(separator: "\n")
            _ = try ProgressStore.append(
                db, taskId: taskId, sessionId: nil, kind: .error, text: "\(Self.worktreeCleanupLead)\n\(listed)"
            )
            if let reportId, let report = try Report.fetchOne(db, key: reportId), report.consumedAt == nil {
                try db.execute(
                    sql: "UPDATE report SET body = body || ? WHERE id = ?",
                    arguments: ["\n\n\(Self.worktreeCleanupLead)\n\(listed)", reportId]
                )
            } else {
                _ = try ReportStore.insert(
                    db, projectId: task.projectId, taskId: taskId, sessionId: nil, kind: .decision,
                    body: "\(Self.worktreeCleanupLead) task \(taskId) (\(task.title))\n\(listed)"
                )
            }
            return true
        }
    }

    /// SPEC §5.2: a human removed the worktrees a done or abandoned epic left on disk. One decision
    /// report says what went and what stayed; each finding also lands on its task's progress.
    @discardableResult
    public func recordEpicWorktreeRemoval(
        epicId: String, removed: [String], findings: [WorktreeCleanupFinding]
    ) throws -> Report {
        try db.writer.write { db in
            guard let epic = try Epic.fetchOne(db, key: epicId) else { throw BoardError.epicNotFound(epicId) }
            for finding in findings {
                guard let taskId = finding.taskId, try Task.fetchOne(db, key: taskId) != nil else { continue }
                _ = try ProgressStore.append(
                    db, taskId: taskId, sessionId: nil, kind: .error, text: "\(Self.worktreeCleanupLead) \(finding.text)"
                )
            }
            var lines = ["A human removed the worktrees epic \(epicId) (\(epic.title)) left on disk."]
            lines.append(
                removed.isEmpty
                    ? "Nothing was removed."
                    : "Removed:\n" + removed.map { "- \($0)" }.joined(separator: "\n")
            )
            if !findings.isEmpty {
                lines.append("Not done:\n" + findings.map { "- \($0.text)" }.joined(separator: "\n"))
            }
            return try ReportStore.insert(
                db, projectId: epic.projectId, taskId: nil, sessionId: nil, kind: .decision,
                body: lines.joined(separator: "\n\n")
            )
        }
    }
}
