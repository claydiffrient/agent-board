import Foundation
import GRDB
import XCTest
@testable import AgentBoardCore

final class PRWatchStoreTests: XCTestCase {
    private func snapshot(number: Int = 7, items: [PRSnapshotItem]) -> PRSnapshot {
        PRSnapshot(
            repoOwner: "example-org", repoName: "app", number: number,
            url: "https://github.com/example-org/app/pull/\(number)", title: "Add a widget",
            headRef: "feature/widget", headOid: "abc123", baseRef: "main", reviewDecision: "REVIEW_REQUIRED",
            checksState: "SUCCESS", mergeable: "MERGEABLE", labels: ["needs-review"], items: items
        )
    }

    private func thread(_ id: String, body: String = "Rename this", resolved: Bool = false) -> PRSnapshotItem {
        PRSnapshotItem(
            githubNodeId: id, kind: .thread, author: "reviewer", body: body, path: "Sources/A.swift", line: 12,
            url: "https://github.com/example-org/app/pull/7#discussion_r1", isResolved: resolved
        )
    }

    func testUpsertIsIdempotentAndHandlesResolvedOrVanishedItems() throws {
        let f = try Fixture.make()
        let store = PRWatchStore(f.db)
        let first = snapshot(items: [thread("T1"), thread("T2", body: "Why not a set?")])

        let created = try store.upsert(projectId: f.project.id, snapshot: first, now: 1_000)
        let itemsAfterFirst = try store.items(watchId: created.id)
        XCTAssertEqual(itemsAfterFirst.map(\.state), [.open, .open])
        XCTAssertEqual(created.lastFeedbackAt, 1_000)
        XCTAssertEqual(created.labels, ["needs-review"])

        let again = try store.upsert(projectId: f.project.id, snapshot: first, now: 2_000)
        var expected = created
        expected.lastPolledAt = 2_000
        XCTAssertEqual(again, expected)
        XCTAssertEqual(try store.get(created.id), expected)
        XCTAssertEqual(try store.items(watchId: created.id), itemsAfterFirst)

        try store.upsert(
            projectId: f.project.id, snapshot: snapshot(items: [thread("T1", resolved: true)]), now: 3_000
        )
        let states = Dictionary(uniqueKeysWithValues: try store.items(watchId: created.id).map { ($0.githubNodeId, $0.state) })
        XCTAssertEqual(states, ["T1": .handled, "T2": .handled])

        try store.upsert(
            projectId: f.project.id, snapshot: snapshot(items: [thread("T1", body: "Still not renamed")]), now: 4_000
        )
        let reopened = try XCTUnwrap(store.items(watchId: created.id).first { $0.githubNodeId == "T1" })
        XCTAssertEqual(reopened.state, .open)
        XCTAssertEqual(try store.get(created.id)?.lastFeedbackAt, 4_000)
    }

    func testPageGroupsWatchesAndBadgeCountsReadyAndDecisions() throws {
        let f = try Fixture.make()
        let other = try f.otherProject()
        let store = PRWatchStore(f.db)
        let ready = try store.upsert(projectId: f.project.id, snapshot: snapshot(number: 1, items: []))
        let decided = try store.upsert(projectId: f.project.id, snapshot: snapshot(number: 2, items: [thread("D1")]))
        let waiting = try store.upsert(projectId: other.id, snapshot: snapshot(number: 3, items: []))
        let merged = try store.upsert(projectId: f.project.id, snapshot: snapshot(number: 4, items: []))
        try store.setState(.readyToVerify, watchId: ready.id)
        try store.setState(.merged, watchId: merged.id)
        try f.db.writer.write { db in
            try db.execute(sql: "UPDATE pr_item SET verdict = 'decision' WHERE github_node_id = 'D1'")
        }
        try store.setPaused(true, watchId: waiting.id)

        let page = try store.page()
        XCTAssertEqual(page.map(\.group), [.readyToVerify, .needsYou, .waitingOnReviewers])
        XCTAssertEqual(page.map { $0.listings.map(\.watch.id) }, [[ready.id], [decided.id], [waiting.id]])
        XCTAssertEqual(page[1].listings[0].openItems, 1)
        XCTAssertEqual(page[1].listings[0].openDecisions, 1)
        XCTAssertEqual(page[2].listings[0].watch.paused, true)
        XCTAssertEqual(try store.page(projectId: other.id).map(\.group), [.waitingOnReviewers])

        XCTAssertEqual(try store.badgeCounts(), [f.project.id: PRBadgeCount(readyToVerify: 1, openDecisions: 1)])
    }

    func testFollowThroughTablesMigrateOntoAnExistingDatabase() throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: configuration)
        try AppDatabase.migrator.migrate(queue, upTo: "task_closed")
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO project (id, name, repo_path, worktree_root, settings_json, created_at) VALUES ('p1', 'p1', '/repo/p1', '/w', '{}', 0)"
            )
        }

        try AppDatabase.migrator.migrate(queue)

        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO pr_watch (id, project_id, repo_owner, repo_name, number, url, title, head_ref, head_oid,
                  base_ref, state, created_at, updated_at)
                VALUES ('w1', 'p1', 'example-org', 'app', 1, 'u', 't', 'h', 'oid', 'main', 'watching', 0, 0)
                """)
            XCTAssertThrowsError(try db.execute(sql: """
                INSERT INTO pr_watch (id, project_id, repo_owner, repo_name, number, url, title, head_ref, head_oid,
                  base_ref, state, created_at, updated_at)
                VALUES ('w2', 'p1', 'example-org', 'app', 1, 'u', 't', 'h', 'oid', 'main', 'watching', 0, 0)
                """))
            XCTAssertEqual(try PRWatch.fetchOne(db, key: "w1")?.state, .watching)
        }
    }

    func testFollowThroughSettingsDefaultOffAndRoundTrip() throws {
        let absent = ProjectSettings.decode("{}").prFollowThrough
        XCTAssertEqual(absent, PRFollowThroughSettings())
        XCTAssertFalse(absent.enabled)
        XCTAssertNil(absent.verificationLabel)
        XCTAssertTrue(absent.requireApproval)
        XCTAssertEqual(absent.settleMinutes, 10)
        XCTAssertEqual(absent.roundCap, 3)
        XCTAssertNil(absent.dailyBudgetUSD)
        XCTAssertNil(absent.verifyCommand)
        XCTAssertFalse(absent.postFactualReplies)
        XCTAssertEqual(absent.roles, PRFollowThroughRoles())
        XCTAssertEqual(absent.privateTerms, [])

        XCTAssertEqual(
            ProjectSettings.decode(#"{"prFollowThrough":{"enabled":true}}"#).prFollowThrough,
            PRFollowThroughSettings(enabled: true)
        )

        var settings = ProjectSettings()
        settings.prFollowThrough = PRFollowThroughSettings(
            enabled: true, verificationLabel: "verified-example", requireApproval: false, settleMinutes: 5,
            roundCap: 2, dailyBudgetUSD: 4.5, verifyCommand: "open {url}", postFactualReplies: true,
            roles: PRFollowThroughRoles(fixer: PRFollowThroughRole(rosterAgentId: "agent-1", model: "sonnet")),
            privateTerms: ["example-org"]
        )
        XCTAssertEqual(ProjectSettings.decode(settings.encoded()), settings)
    }

    func testVerifyCommandFillsInTheURLAndRefusesOneAShellWouldParse() {
        var settings = PRFollowThroughSettings()
        let url = "https://github.com/example-org/app/pull/7"
        XCTAssertNil(settings.verifyCommand(for: url), "no template, no command")

        settings.verifyCommand = "verify-example --pr {url}"
        XCTAssertEqual(settings.verifyCommand(for: url), "verify-example --pr \(url)")
        XCTAssertNil(settings.verifyCommand(for: url + ";touch x"))
    }
}
