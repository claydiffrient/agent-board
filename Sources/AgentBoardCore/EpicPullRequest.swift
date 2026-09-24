import Foundation
import GRDB

/// A PR-open epic and the pull request the merge check reads for it (SPEC §5.2).
public struct EpicPullRequestCheck: Sendable, Equatable {
    public var epic: Epic
    public var pullRequest: PullRequestReference
}

extension Board {
    public func epicPullRequestChecks(projectId: String? = nil, epicId: String? = nil) throws -> [EpicPullRequestCheck] {
        try db.reader.read { db in
            let epics = try Epic.fetchAll(
                db,
                sql: """
                SELECT * FROM epic
                WHERE state = ?1 AND (?2 IS NULL OR project_id = ?2) AND (?3 IS NULL OR id = ?3)
                ORDER BY created_at, rowid
                """,
                arguments: [EpicState.pullRequestOpen, projectId, epicId]
            )
            return try epics.compactMap { epic in
                try ApprovalStore.publishedEpicPullRequest(db, epicId: epic.id)
                    .map { EpicPullRequestCheck(epic: epic, pullRequest: $0) }
            }
        }
    }

    /// The epic's pull request merged: the epic is `done`, each of `landedTaskIds` is landed with the
    /// merge commit, and a `decision` report says so. False, writing nothing, when the epic has left
    /// `pullRequestOpen` or recorded a newer pull request since the check read it.
    @discardableResult
    public func landEpicPullRequest(
        epicId: String, pullRequest: PullRequestReference, commit: String?, landedTaskIds: [String]
    ) throws -> Bool {
        try db.writer.write { db in
            guard let epic = try Self.stillAwaiting(db, epicId: epicId, pullRequest: pullRequest) else { return false }
            try EpicStore.setState(db, epicId, .done)
            let detail = PullRequestLanding.mergedDetail(pullRequest, commit: commit)
            for taskId in landedTaskIds {
                try TaskStore.setLanding(db, taskId, .landed, detail: detail)
            }
            if try Self.settings(db, projectId: epic.projectId).archivePolicy == .afterEpicMerge {
                _ = try ArchiveSweep.archiveEpic(db, epicId: epicId, at: .nowMillis)
            }
            let unfinished = try Task.fetchAll(
                db, sql: "SELECT * FROM task WHERE epic_id = ? AND column_name != 'done' ORDER BY ordering", arguments: [epicId]
            )
            var text = "Epic \(epicId) (\(epic.title)) is done: pull request #\(pullRequest.number) merged"
                + (commit.map { " as \($0)" } ?? "") + " (\(pullRequest.url))."
            if !unfinished.isEmpty {
                text += " \(unfinished.count) task(s) in it were not done and did not ride that pull request: "
                    + unfinished.map { "\($0.id) (\($0.column.rawValue))" }.joined(separator: ", ") + "."
            }
            try Self.recordOnEpic(db, epic: epic, text: text, kind: .status)
            return true
        }
    }

    /// The epic's pull request closed without merging: the epic goes back to `active`, and a
    /// `decision` report carries the reason. Nil, writing nothing, under the same guard as
    /// `landEpicPullRequest`.
    @discardableResult
    public func reopenEpicAfterClosedPullRequest(epicId: String, pullRequest: PullRequestReference) throws -> Report? {
        try db.writer.write { db in
            guard let epic = try Self.stillAwaiting(db, epicId: epicId, pullRequest: pullRequest) else { return nil }
            try EpicStore.setState(db, epicId, .active)
            let text = "Epic \(epicId) (\(epic.title)) is active again: pull request #\(pullRequest.number) was closed "
                + "without merging (\(pullRequest.url)). Reopen it, or open a new one with "
                + "`open_pull_request(epic_id: \"\(epicId)\")`; nothing reached the base branch."
            return try Self.recordOnEpic(db, epic: epic, text: text, kind: .error)
        }
    }

    private static func stillAwaiting(_ db: Database, epicId: String, pullRequest: PullRequestReference) throws -> Epic? {
        guard let epic = try Epic.fetchOne(db, key: epicId), epic.state == .pullRequestOpen,
              try ApprovalStore.publishedEpicPullRequest(db, epicId: epicId) == pullRequest
        else { return nil }
        return epic
    }

    @discardableResult
    private static func recordOnEpic(_ db: Database, epic: Epic, text: String, kind: ProgressKind) throws -> Report {
        if let taskId = try epicCardTask(db, epicId: epic.id) {
            _ = try ProgressStore.append(db, taskId: taskId, sessionId: nil, kind: kind, text: text)
        }
        return try ReportStore.insert(
            db, projectId: epic.projectId, taskId: nil, sessionId: nil, kind: .decision, body: text
        )
    }
}
