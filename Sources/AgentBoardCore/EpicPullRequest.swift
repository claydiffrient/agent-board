import Foundation
import GRDB

/// A PR-open epic and the pull request the merge check reads for it (SPEC §5.2).
public struct EpicPullRequestCheck: Sendable, Equatable {
    public var epic: Epic
    public var pullRequest: PullRequestReference
}

/// Which of an epic's `done` tasks its merged pull request carried (SPEC §5.2).
public struct EpicCarriage: Sendable, Equatable {
    public var landed: [String]
    /// On the epic branch but not in the merged head: accepted after the pull request's last push.
    public var late: [String]
    /// Marked `.landed` with nothing left to check against the merged head.
    public var unverified: [String]
    /// Why the merged head could not be read, when it could not. Then no task is judged.
    public var headUnresolved: String?

    public init(landed: [String] = [], late: [String] = [], unverified: [String] = [], headUnresolved: String? = nil) {
        self.landed = landed
        self.late = late
        self.unverified = unverified
        self.headUnresolved = headUnresolved
    }

    /// The full object ids a landing detail names.
    public static func recordedCommits(in detail: String?) -> [String] {
        guard let detail else { return [] }
        return detail.matches(of: #/\b(?:[0-9a-f]{64}|[0-9a-f]{40})\b/#).map { String($0.output) }
    }
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

    /// The epic's pull request merged: the epic is `done`, `carriage` settles its tasks' landings, and
    /// a `decision` report says so. False, writing nothing, when the epic has left `pullRequestOpen`
    /// or recorded a newer pull request since the check read it.
    @discardableResult
    public func landEpicPullRequest(
        epicId: String, pullRequest: PullRequestReference, commit: String?, carriage: EpicCarriage
    ) throws -> Bool {
        try db.writer.write { db in
            guard let epic = try Self.stillAwaiting(db, epicId: epicId, pullRequest: pullRequest) else { return false }
            try EpicStore.setState(db, epicId, .done)
            let detail = PullRequestLanding.mergedDetail(pullRequest, commit: commit)
            for taskId in carriage.landed {
                try TaskStore.setLanding(db, taskId, .landed, detail: detail)
            }
            let lateAdvice = "accepted after the PR's last push; push the epic branch and open a follow-up PR"
            for taskId in carriage.late {
                try TaskStore.setLanding(
                    db, taskId, .unlanded,
                    detail: "Not in pull request #\(pullRequest.number) as merged (\(pullRequest.url)): \(lateAdvice)."
                )
            }
            let unverifiedReason = "no branch, reaped tip, or recorded commit is left to check against the merged head"
            for taskId in carriage.unverified {
                try TaskStore.setLanding(
                    db, taskId, .pending,
                    detail: "Pull request #\(pullRequest.number) merged (\(pullRequest.url)), but whether it carried "
                        + "this task could not be verified: \(unverifiedReason)."
                )
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
            if let reason = carriage.headUnresolved {
                text += " Which of its tasks the pull request carried could not be verified (\(reason)), "
                    + "so their landings are unchanged."
            }
            if !carriage.late.isEmpty {
                text += " Not landed: " + carriage.late.joined(separator: ", ") + " — \(lateAdvice)."
            }
            if !carriage.unverified.isEmpty {
                text += " Could not verify whether it carried " + carriage.unverified.joined(separator: ", ")
                    + ": \(unverifiedReason)."
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
