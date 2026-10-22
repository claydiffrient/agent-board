import Foundation
import GRDB

extension PRWatchStore {
    public static let maxVerifyFailureLength = 4000

    /// The live watch of `projectId` whose pull request `url` names, matched on owner, repository and
    /// number so a trailing path or a differently cased owner still finds it.
    public func liveWatch(url: String, projectId: String) throws -> PRWatch? {
        guard let match = url.trimmingCharacters(in: .whitespacesAndNewlines).firstMatch(of: #/^https?://github\.com/([^/\s]+)/([^/\s]+)/pull/(\d+)(?:[/?#]\S*)?$/#),
              let number = Int(match.3)
        else { return nil }
        return try db.reader.read { db in
            try PRWatch.fetchOne(
                db,
                sql: """
                SELECT * FROM pr_watch WHERE project_id = ? AND repo_owner = ? COLLATE NOCASE
                AND repo_name = ? COLLATE NOCASE AND number = ? AND state NOT IN ('merged', 'closed')
                """,
                arguments: [projectId, String(match.1), String(match.2), number]
            )
        }
    }

    /// Records a failure found while verifying the pull request by hand (SPEC §13.1). On a verified
    /// watch it becomes a frozen decision and the watch stays verified; from watching, settling or
    /// readyToVerify the watch goes to settling; mid-round it waits for the next round like any feedback.
    @discardableResult
    public func addVerifyFailure(watchId: String, body: String, now: Int64 = .nowMillis) throws -> PRItem {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw PRVerdictRejection("The verification failure is empty.") }
        guard text.count <= Self.maxVerifyFailureLength else {
            throw PRVerdictRejection("The verification failure is over \(Self.maxVerifyFailureLength) characters.")
        }
        return try db.writer.write { db in
            guard var watch = try PRWatch.fetchOne(db, key: watchId), !watch.state.isTerminal else {
                throw PRVerdictRejection("That pull request is not watched.")
            }
            var item = PRItem(
                id: nil, watchId: watchId, githubNodeId: "verify:\(BoardId.new())", kind: .verifyFailure,
                author: nil, body: text, path: nil, line: nil, url: nil, state: .open, round: watch.round,
                createdAt: now, updatedAt: now
            )
            try item.insert(db)
            if watch.state == .verified {
                try Self.freeze(db, sql: "id = ?", arguments: [item.id], now: now)
                item = try PRItem.fetchOne(db, key: item.id) ?? item
            } else {
                if [.watching, .settling, .readyToVerify].contains(watch.state) { watch.state = .settling }
                watch.lastFeedbackAt = now
            }
            watch.updatedAt = now
            try watch.update(db)
            return item
        }
    }
}
