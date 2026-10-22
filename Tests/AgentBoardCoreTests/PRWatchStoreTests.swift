import Foundation
import GRDB
import XCTest
@testable import AgentBoardCore

final class PRWatchStoreTests: XCTestCase {
    private func snapshot(number: Int = 7, head: String = "abc123", items: [PRSnapshotItem]) -> PRSnapshot {
        PRSnapshot(
            repoOwner: "example-org", repoName: "app", number: number,
            url: "https://github.com/example-org/app/pull/\(number)", title: "Add a widget",
            headRef: "feature/widget", headOid: head, baseRef: "main", reviewDecision: "REVIEW_REQUIRED",
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

    func testANewHeadOidStampsHeadChangedAtAndAnUnchangedSnapshotLeavesItAlone() throws {
        let f = try Fixture.make()
        let store = PRWatchStore(f.db)
        let created = try store.upsert(projectId: f.project.id, snapshot: snapshot(items: []), now: 1_000)
        XCTAssertNil(created.headChangedAt, "the head was already there when watching began")

        let pushed = try store.upsert(projectId: f.project.id, snapshot: snapshot(head: "def456", items: []), now: 2_000)
        XCTAssertEqual(pushed.headChangedAt, 2_000)

        let polled = try store.upsert(projectId: f.project.id, snapshot: snapshot(head: "def456", items: []), now: 3_000)
        XCTAssertEqual(polled.headChangedAt, 2_000)
        XCTAssertEqual(try store.get(created.id)?.headChangedAt, 2_000)
    }

    @discardableResult
    private func triage(_ f: Fixture, watchId: String, as verdict: PRItemVerdict) throws -> PRWatchState? {
        let store = PRWatchStore(f.db)
        try store.setState(.settling, watchId: watchId)
        XCTAssertNotNil(try store.beginTriageRound(watchId: watchId))
        try f.db.writer.write { db in
            try db.execute(
                sql: "UPDATE pr_item SET verdict = ?, approach = 'Rename it.' WHERE watch_id = ?",
                arguments: [verdict, watchId]
            )
        }
        return try f.board.applyVerdicts(watchId: watchId)
    }

    private func enableFollowThrough(_ f: Fixture, _ enabled: Bool) throws {
        var settings = try XCTUnwrap(f.projects.get(f.project.id)).settings
        settings.prFollowThrough.enabled = enabled
        try f.projects.updateSettings(f.project.id, settings)
    }

    func testStartingAFixRoundHoldsEveryFixItemAndClosesTheWatchsStaleBacklogFixTasks() throws {
        let f = try Fixture.make()
        let store = PRWatchStore(f.db)
        let watch = try store.upsert(
            projectId: f.project.id, snapshot: snapshot(items: [thread("T1"), thread("T2", body: "Use a set.")]), now: 1_000
        )
        let stale = try f.db.writer.write { db in
            let task = try TaskStore.insert(
                db, projectId: f.project.id, title: "Fix from #7: Rename this", body: nil, acceptance: nil,
                priority: nil, column: .backlog, origin: .followThrough, epicId: nil, type: .code
            )
            try db.execute(sql: "UPDATE pr_item SET fix_task_id = ? WHERE github_node_id = 'T1'", arguments: [task.id])
            return task
        }
        XCTAssertEqual(try triage(f, watchId: watch.id, as: .fix), .fixing)

        let task = try XCTUnwrap(f.board.createFixRoundTask(watchId: watch.id, model: "fixer-model"))
        XCTAssertNil(try f.board.createFixRoundTask(watchId: watch.id, model: nil), "one task per round")
        XCTAssertEqual(task.column, .ready)
        XCTAssertEqual(task.origin, .fixRound)
        XCTAssertEqual(task.model, "fixer-model")
        for part in ["Rename this", "Use a set.", "Sources/A.swift:12", "Rename it.", "agentboard/pr-7-r1"] {
            XCTAssertTrue(task.body?.contains(part) == true, "\(part) is missing from:\n\(task.body ?? "")")
        }
        XCTAssertEqual(try store.rounds(watchId: watch.id).map(\.fixTaskId), [task.id])
        XCTAssertEqual(try store.items(watchId: watch.id).map(\.fixTaskId), [task.id, task.id])
        let closed = try XCTUnwrap(f.tasks.get(stale.id))
        XCTAssertEqual(closed.column, .closed)
        XCTAssertTrue(closed.closedReason?.contains("round 1") == true, closed.closedReason ?? "")
    }

    func testAFixRoundSkipsSpawnApprovalOnlyWhereFollowThroughIsOn() throws {
        let f = try Fixture.make()
        let store = PRWatchStore(f.db)
        let watch = try store.upsert(projectId: f.project.id, snapshot: snapshot(items: [thread("T1")]))
        try triage(f, watchId: watch.id, as: .fix)
        let task = try XCTUnwrap(f.board.createFixRoundTask(watchId: watch.id, model: nil))

        try enableFollowThrough(f, true)
        XCTAssertEqual(try f.board.requestSpawn(taskId: task.id, requestedBy: "follow-through"), .proceed)
        try enableFollowThrough(f, false)
        guard case .approvalPending = try f.board.requestSpawn(taskId: task.id, requestedBy: "follow-through") else {
            return XCTFail("a disabled project's fix round waits for approval")
        }
    }

    func testAStackedPullRequestParksInsteadOfFixing() throws {
        let f = try Fixture.make()
        let store = PRWatchStore(f.db)
        var stacked = snapshot(items: [thread("T1")])
        stacked.baseRef = "feature/lower-layer"
        let watch = try store.upsert(projectId: f.project.id, snapshot: stacked)

        XCTAssertEqual(try triage(f, watchId: watch.id, as: .fix), .parked)
        XCTAssertTrue(try store.get(watch.id)?.parkedReason?.contains("feature/lower-layer") == true)
        XCTAssertNil(try f.board.createFixRoundTask(watchId: watch.id, model: nil))
    }

    func testAReplyOnADecisionClearsItsVerdictAndAnswerWhetherItWasHandledOrStillOpen() throws {
        let f = try Fixture.make()
        let store = PRWatchStore(f.db)
        let watch = try store.upsert(
            projectId: f.project.id, snapshot: snapshot(items: [thread("Answered"), thread("Waiting")]), now: 1_000
        )
        try f.db.writer.write { db in
            try db.execute(sql: """
                UPDATE pr_item SET verdict = 'decision', decision_question = 'Async?', decision_options_json = '["Yes"]',
                  decision_answer = 'Yes', reply_body = 'Done.'
                """)
            try db.execute(sql: "UPDATE pr_item SET state = 'handled' WHERE github_node_id = 'Answered'")
        }

        try store.upsert(
            projectId: f.project.id,
            snapshot: snapshot(items: [thread("Answered", body: "Reconsider."), thread("Waiting", body: "Reconsider.")]),
            now: 2_000
        )
        for item in try store.items(watchId: watch.id) {
            XCTAssertEqual(item.state, .open, item.githubNodeId)
            XCTAssertNil(item.verdict, item.githubNodeId)
            XCTAssertNil(item.decisionQuestion, item.githubNodeId)
            XCTAssertNil(item.decisionAnswer, item.githubNodeId)
            XCTAssertNil(item.replyBody, item.githubNodeId)
        }
    }

    func testPageGroupsWatchesAndBadgeCountsReadyAndDecisions() throws {
        let f = try Fixture.make()
        let other = try f.otherProject()
        let store = PRWatchStore(f.db)
        var settings = f.project.settings
        settings.prFollowThrough.enabled = true
        try ProjectStore(f.db).updateSettings(f.project.id, settings)
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

    private func setReplies(_ f: Fixture, _ on: Bool, now: Int64) throws {
        var settings = try XCTUnwrap(f.projects.get(f.project.id)).settings
        settings.prFollowThrough.postFactualReplies = on
        try f.projects.updateSettings(f.project.id, settings, now: now)
    }

    private func answer(_ f: Fixture, _ nodeId: String) throws {
        try f.db.writer.write { db in
            try db.execute(
                sql: "UPDATE pr_item SET verdict = 'answer', reply_body = 'Three retries.' WHERE github_node_id = ?",
                arguments: [nodeId]
            )
        }
    }

    func testTurningRepliesOnOwesNoReplyForAnItemHandledBeforeThen() throws {
        let f = try Fixture.make()
        let store = PRWatchStore(f.db)
        let watch = try store.upsert(projectId: f.project.id, snapshot: snapshot(items: [thread("T1"), thread("T2")]), now: 1_000)
        try answer(f, "T1")
        try answer(f, "T2")
        try store.upsert(projectId: f.project.id, snapshot: snapshot(items: [thread("T2")]), now: 2_000)

        try setReplies(f, true, now: 3_000)
        XCTAssertEqual(try store.pendingReplies(watchId: watch.id).map(\.githubNodeId), [])

        try store.upsert(projectId: f.project.id, snapshot: snapshot(items: []), now: 4_000)
        try setReplies(f, true, now: 5_000)
        XCTAssertEqual(try store.pendingReplies(watchId: watch.id).map(\.githubNodeId), ["T2"])
    }

    /// The round's fix task is deleted after its push, which nulls `fix_task_id` on both the round and the item.
    func testAPushedFixWhoseTaskWasDeletedStillOwesItsReplyAndAReopenedItemOwesAFreshOne() throws {
        let f = try Fixture.make()
        let store = PRWatchStore(f.db)
        try setReplies(f, true, now: 500)
        let watch = try store.upsert(projectId: f.project.id, snapshot: snapshot(items: [thread("T1")]), now: 1_000)
        try triage(f, watchId: watch.id, as: .fix)
        let task = try XCTUnwrap(f.board.createFixRoundTask(watchId: watch.id, model: nil))
        try store.setState(.publishing, watchId: watch.id)
        try f.board.recordRoundPublished(watchId: watch.id, pushedHeadOid: "def456", now: 2_000)
        try f.tasks.delete(task.id)

        let fixed = try XCTUnwrap(try store.pendingReplies(watchId: watch.id).first)
        try store.recordReply(itemId: try XCTUnwrap(fixed.id), url: "https://github.com/example-org/app/pull/7#r1")
        XCTAssertEqual(try store.pendingReplies(watchId: watch.id).map(\.githubNodeId), [])

        try store.upsert(projectId: f.project.id, snapshot: snapshot(items: [thread("T1", body: "Still not renamed")]), now: 3_000)
        try answer(f, "T1")
        try store.upsert(projectId: f.project.id, snapshot: snapshot(items: [thread("T1", resolved: true)]), now: 4_000)
        XCTAssertEqual(try store.pendingReplies(watchId: watch.id).map(\.githubNodeId), ["T1"])
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

    func testAVerifyFailureSentBackMidRoundLeavesTheRoundAlone() throws {
        let f = try Fixture.make()
        let store = PRWatchStore(f.db)
        let watch = try store.upsert(projectId: f.project.id, snapshot: snapshot(items: [thread("T1")]), now: 1_000)
        try store.setState(.settling, watchId: watch.id)
        XCTAssertEqual(try store.beginTriageRound(watchId: watch.id, now: 2_000)?.number, 1)
        XCTAssertEqual(try store.get(watch.id)?.state, .triaging)

        let item = try store.addVerifyFailure(watchId: watch.id, body: "Still broken in prod.", now: 3_000)

        let after = try XCTUnwrap(store.get(watch.id))
        XCTAssertEqual(after.state, .triaging, "a send-back mid-round must not force the watch to settling")
        XCTAssertEqual(after.round, 1, "the round must not be disturbed")
        XCTAssertEqual(item.round, 1, "the item carries the round in progress")
        XCTAssertEqual(after.lastFeedbackAt, 3_000)
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
