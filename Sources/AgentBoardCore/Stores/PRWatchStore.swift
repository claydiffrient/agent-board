import Foundation
import GRDB

public struct PRWatchStore: Sendable {
    let db: AppDatabase

    public init(_ db: AppDatabase) {
        self.db = db
    }

    /// Records one poll (SPEC §4). Idempotent by node id: an unchanged snapshot moves only
    /// `last_polled_at`, and a new head oid stamps `head_changed_at`. An open item that resolved or left the snapshot becomes handled,
    /// except the failed-checks item of a head whose checks still fail.
    /// An item whose body changed (a new reply) is open and untriaged again, owing a fresh reply; one that
    /// reopens also drops its task.
    @discardableResult
    public func upsert(projectId: String, snapshot: PRSnapshot, now: Int64 = .nowMillis) throws -> PRWatch {
        try db.writer.write { db in
            let existing = try PRWatch.fetchOne(
                db,
                sql: "SELECT * FROM pr_watch WHERE project_id = ? AND repo_owner = ? AND repo_name = ? AND number = ?",
                arguments: [projectId, snapshot.repoOwner, snapshot.repoName, snapshot.number]
            )
            var watch = existing ?? PRWatch(
                id: PRWatch.newId(), projectId: projectId, repoOwner: snapshot.repoOwner,
                repoName: snapshot.repoName, number: snapshot.number, url: snapshot.url, title: snapshot.title,
                isDraft: snapshot.isDraft, headRef: snapshot.headRef, headOid: snapshot.headOid,
                baseRef: snapshot.baseRef, state: .watching, round: 0, reviewDecision: snapshot.reviewDecision,
                checksState: snapshot.checksState, mergeable: snapshot.mergeable,
                labelsJSON: PRWatch.encodeLabels(snapshot.labels), paused: false, lastPolledAt: now,
                lastFeedbackAt: nil, verifiedAt: nil, estCostUSD: 0, createdAt: now, updatedAt: now
            )
            if let existing {
                watch.url = snapshot.url
                watch.title = snapshot.title
                watch.isDraft = snapshot.isDraft
                watch.headRef = snapshot.headRef
                if watch.headOid != snapshot.headOid { watch.headChangedAt = now }
                watch.headOid = snapshot.headOid
                watch.baseRef = snapshot.baseRef
                watch.reviewDecision = snapshot.reviewDecision
                watch.checksState = snapshot.checksState
                watch.mergeable = snapshot.mergeable
                watch.labels = snapshot.labels
                if watch != existing { watch.updatedAt = now }
                watch.lastPolledAt = now
                try watch.update(db)
            } else {
                try watch.insert(db)
            }

            var feedbackArrived = false
            var stored = Dictionary(
                uniqueKeysWithValues: try PRItem.filter(Column("watch_id") == watch.id).fetchAll(db)
                    .map { ($0.githubNodeId, $0) }
            )
            for incoming in snapshot.items {
                guard var item = stored.removeValue(forKey: incoming.githubNodeId) else {
                    if incoming.isResolved { continue }
                    var item = PRItem(
                        id: nil, watchId: watch.id, githubNodeId: incoming.githubNodeId, kind: incoming.kind,
                        author: incoming.author, body: incoming.body, path: incoming.path, line: incoming.line,
                        url: incoming.url, state: .open, round: watch.round, createdAt: now, updatedAt: now
                    )
                    try item.insert(db)
                    feedbackArrived = true
                    continue
                }
                let before = item
                let bodyChanged = item.body != incoming.body
                item.kind = incoming.kind
                item.author = incoming.author
                item.body = incoming.body
                item.path = incoming.path
                item.line = incoming.line
                item.url = incoming.url
                if incoming.isResolved {
                    if item.state == .open {
                        item.state = .handled
                        item.handledAt = now
                    }
                } else if bodyChanged {
                    if item.state != .open {
                        item.state = .open
                        item.fixTaskId = nil
                        item.round = watch.round
                    }
                    item.verdict = nil
                    item.approach = nil
                    item.decisionQuestion = nil
                    item.decisionOptionsJSON = nil
                    item.decisionAnswer = nil
                    item.decisionNotifiedAt = nil
                    item.replyBody = nil
                    item.replyURL = nil
                    item.replyError = nil
                    item.replyAbandonedAt = nil
                    item.followupGrade = nil
                    feedbackArrived = true
                }
                if item != before {
                    item.updatedAt = now
                    try item.update(db)
                }
            }
            let failingChecks = PRWatchTransition.checksFailed(snapshot.checksState)
                ? PRItem.checksNodeId(head: snapshot.headOid) : nil
            for var gone in stored.values where gone.state == .open && gone.githubNodeId != failingChecks {
                gone.state = .handled
                gone.handledAt = now
                gone.updatedAt = now
                try gone.update(db)
            }

            if feedbackArrived {
                watch.lastFeedbackAt = now
                watch.updatedAt = now
                try watch.update(db)
            }
            return watch
        }
    }

    public func get(_ id: String) throws -> PRWatch? {
        try db.reader.read { try PRWatch.fetchOne($0, key: id) }
    }

    public func items(watchId: String) throws -> [PRItem] {
        try db.reader.read { db in
            try PRItem.filter(Column("watch_id") == watchId).order(Column("created_at"), Column("id")).fetchAll(db)
        }
    }

    public func setState(_ state: PRWatchState, watchId: String, now: Int64 = .nowMillis) throws {
        try db.writer.write { db in
            try db.execute(
                sql: "UPDATE pr_watch SET state = ?, updated_at = ? WHERE id = ?",
                arguments: [state, now, watchId]
            )
        }
    }

    /// Records that `watchId`'s Ready to verify banner fires for its current head, and returns the
    /// watch when this call is the one that recorded it (SPEC §13.4). Nil when the watch is not ready
    /// to verify or this head was already announced, so a PR that stays ready across polls, or
    /// leaves and re-enters without a push, announces itself once.
    public func claimReadyNotification(watchId: String) throws -> PRWatch? {
        try db.writer.write { db in
            guard var watch = try PRWatch.fetchOne(db, key: watchId),
                  watch.state == .readyToVerify, watch.readyNotifiedOid != watch.headOid
            else { return nil }
            watch.readyNotifiedOid = watch.headOid
            try watch.update(db)
            return watch
        }
    }

    public func delete(watchId: String) throws {
        _ = try db.writer.write { try PRWatch.deleteOne($0, key: watchId) }
    }

    /// Every watch of `projectId` that is not merged or closed.
    public func live(projectId: String) throws -> [PRWatch] {
        try db.reader.read { db in
            try PRWatch.fetchAll(
                db,
                sql: "SELECT * FROM pr_watch WHERE project_id = ? AND state NOT IN ('merged', 'closed') ORDER BY number",
                arguments: [projectId]
            )
        }
    }

    /// Makes the keys of `problems` exactly the projects whose poll cannot run, each with its
    /// detail. A project already recorded keeps its row untouched, so a failure repeated every poll
    /// writes nothing and raises the attention signal once.
    public func setPollProblems(_ problems: [String: String], now: Int64 = .nowMillis) throws {
        let recorded = Set(try db.reader.read { try String.fetchAll($0, sql: "SELECT project_id FROM pr_poll_problem") })
        let wanted = Set(problems.keys)
        guard recorded != wanted else { return }
        try db.writer.write { db in
            for gone in recorded.subtracting(wanted) {
                try db.execute(sql: "DELETE FROM pr_poll_problem WHERE project_id = ?", arguments: [gone])
            }
            for added in wanted.subtracting(recorded) {
                try db.execute(
                    sql: "INSERT INTO pr_poll_problem (project_id, detail, since) VALUES (?, ?, ?)",
                    arguments: [added, problems[added], now]
                )
            }
        }
    }

    /// Records one project's problem between polls, keeping a row it already has.
    public func addPollProblem(projectId: String, detail: String, now: Int64 = .nowMillis) throws {
        try db.writer.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO pr_poll_problem (project_id, detail, since) VALUES (?, ?, ?)",
                arguments: [projectId, detail, now]
            )
        }
    }

    public func setPaused(_ paused: Bool, watchId: String, now: Int64 = .nowMillis) throws {
        try db.writer.write { db in
            try db.execute(
                sql: "UPDATE pr_watch SET paused = ?, updated_at = ? WHERE id = ?",
                arguments: [paused, now, watchId]
            )
        }
    }

    /// Records Mark verified once `gh` has added `label`, so the page moves the row without waiting
    /// for the next poll to read the label back.
    public func markVerified(watchId: String, label: String, now: Int64 = .nowMillis) throws {
        try db.writer.write { db in
            guard var watch = try PRWatch.fetchOne(db, key: watchId) else { return }
            if !watch.labels.contains(where: { $0.caseInsensitiveCompare(label) == .orderedSame }) {
                watch.labels.append(label)
            }
            watch.state = .verified
            watch.verifiedAt = now
            watch.updatedAt = now
            try watch.update(db)
        }
    }

    /// The Pull Requests page: every non-empty group in display order, newest change first within
    /// each. Nil `projectId` lists every project.
    public func page(projectId: String? = nil) throws -> [PRWatchGroup] {
        try db.reader.read { try Self.page($0, projectId: projectId) }
    }

    public func observePage(projectId: String? = nil) -> ValueObservation<ValueReducers.Fetch<[PRWatchGroup]>> {
        ValueObservation.tracking { try Self.page($0, projectId: projectId) }
    }

    static func page(_ db: Database, projectId: String?) throws -> [PRWatchGroup] {
        var sql = """
        SELECT w.*,
          (SELECT COUNT(*) FROM pr_item i WHERE i.watch_id = w.id AND i.state = 'open') AS open_items
        FROM pr_watch w
        WHERE w.state NOT IN ('merged', 'closed')
        """
        var arguments: StatementArguments = []
        if let projectId {
            sql += " AND w.project_id = ?"
            arguments += [projectId]
        }
        sql += " ORDER BY w.updated_at DESC, w.number DESC"
        let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
        let decisions = Dictionary(
            grouping: try PRItem.fetchAll(
                db,
                sql: """
                SELECT i.* FROM pr_item i JOIN pr_watch w ON w.id = i.watch_id
                WHERE i.state = 'open' AND i.verdict = 'decision' AND w.state NOT IN ('merged', 'closed')
                ORDER BY i.created_at, i.id
                """
            ),
            by: \.watchId
        )
        let listings = try rows.map { row in
            let watch = try PRWatch(row: row)
            return PRWatchListing(watch: watch, openItems: row["open_items"], decisions: decisions[watch.id] ?? [])
        }
        let grouped = Dictionary(grouping: listings) {
            PRPageGroup.of($0.watch.state, openDecisions: $0.openDecisions)
        }
        return PRPageGroup.allCases.compactMap { group in
            grouped[group].map { PRWatchGroup(group: group, listings: $0) }
        }
    }

    /// Per project, for the sidebar badge and At a Glance. A project with nothing to count is absent,
    /// and so is every project with follow-through off and every paused watch (SPEC §13.4).
    public func badgeCounts() throws -> [String: PRBadgeCount] {
        try db.reader.read(Self.badgeCounts)
    }

    public func observeBadgeCounts() -> ValueObservation<ValueReducers.Fetch<[String: PRBadgeCount]>> {
        ValueObservation.tracking(Self.badgeCounts)
    }

    /// The SQL condition, on a `pr_watch w` joined to its `project p`, that a watch counts toward
    /// the badge, the attention signal and the banners.
    static let countsTowardAttention = """
        json_extract(p.settings_json, '$.prFollowThrough.enabled') = 1 AND w.paused = 0
        """

    static func badgeCounts(_ db: Database) throws -> [String: PRBadgeCount] {
        var counts: [String: PRBadgeCount] = [:]
        let ready = try Row.fetchAll(
            db,
            sql: """
            SELECT w.project_id, COUNT(*) AS n FROM pr_watch w JOIN project p ON p.id = w.project_id
            WHERE w.state = 'ready_to_verify' AND \(countsTowardAttention)
            GROUP BY w.project_id
            """
        )
        for row in ready {
            counts[row["project_id"], default: PRBadgeCount()].readyToVerify = row["n"]
        }
        let decisions = try Row.fetchAll(
            db,
            sql: """
            SELECT w.project_id, COUNT(*) AS n
            FROM pr_item i JOIN pr_watch w ON w.id = i.watch_id JOIN project p ON p.id = w.project_id
            WHERE i.state = 'open' AND i.verdict = 'decision' AND w.state NOT IN ('merged', 'closed')
              AND \(countsTowardAttention)
            GROUP BY w.project_id
            """
        )
        for row in decisions {
            counts[row["project_id"], default: PRBadgeCount()].openDecisions = row["n"]
        }
        return counts
    }

    /// Records that each of `watchId`'s open decisions not yet announced has had its banner, and
    /// returns those, so each decision announces itself once (SPEC §13.4). A new reply on its thread
    /// clears the record along with the verdict.
    public func claimDecisionNotifications(watchId: String, now: Int64 = .nowMillis) throws -> [PRItem] {
        try db.writer.write { db in
            let unannounced = try PRItem.fetchAll(
                db,
                sql: """
                SELECT * FROM pr_item
                WHERE watch_id = ? AND state = 'open' AND verdict = 'decision' AND decision_notified_at IS NULL
                ORDER BY created_at, id
                """,
                arguments: [watchId]
            )
            for var item in unannounced {
                item.decisionNotifiedAt = now
                try item.update(db)
            }
            return unannounced
        }
    }
}
