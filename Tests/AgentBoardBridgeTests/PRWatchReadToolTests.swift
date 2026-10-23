import AgentBoardBridge
import AgentBoardCore
import AgentBoardServer
import Foundation
import XCTest

/// SPEC §6 and §13.6: the orchestrator reads follow-through's state, and nothing it reads changes it.
final class PRWatchReadToolTests: XCTestCase {
    private var f: BridgeFixture!
    private var watches: PRWatchStore!
    private var checkTask: BoardTask!

    private let parkedReason = "#12 round 2's check never ran 3 times.\nSecond line the report drops."
    private let longBody = String(repeating: "Rename the helper. ", count: 40)

    override func setUpWithError() throws {
        f = try BridgeFixture.make()
        watches = PRWatchStore(f.db)
    }

    override func tearDown() {
        f = nil
        watches = nil
    }

    /// A parked watch with a thread whose reply failed, a decision, and two rounds.
    private func seed() throws -> PRWatch {
        let watch = try watches.upsert(projectId: f.project.id, snapshot: PRSnapshot(
            repoOwner: "example-org", repoName: "app", number: 12,
            url: "https://github.com/example-org/app/pull/12", title: "Change 12",
            headRef: "feature-12", headOid: String(repeating: "a", count: 40), baseRef: "main",
            reviewDecision: "CHANGES_REQUESTED", checksState: "SUCCESS",
            items: [
                PRSnapshotItem(
                    githubNodeId: "T1", kind: .thread, author: "reviewer", body: longBody,
                    url: "https://github.com/example-org/app/pull/12#discussion_r1"
                ),
                PRSnapshotItem(githubNodeId: "R1", kind: .review, author: "lead", body: "Which name?"),
            ]
        ))
        let fixTask = try f.task("fix round 2")
        checkTask = try f.task("check round 2")
        let options = #"[{"label":"Keep it","verdict":"answer","reply_body":"Kept."},{"label":"Rename","verdict":"fix"}]"#
        try f.db.writer.write { db in
            try db.execute(
                sql: """
                UPDATE pr_watch SET state = 'parked', round = 2, parked_reason = ? WHERE id = ?;
                UPDATE pr_item SET verdict = 'fix', round = 2, reply_error = 'HTTP 502', followup_grade = 'partly',
                  followup_note = 'Half renamed.' WHERE github_node_id = 'T1';
                UPDATE pr_item SET verdict = 'decision', decision_question = 'Keep the name?',
                  decision_options_json = ?, decision_answer = 'Rename', answers = 'lead' WHERE github_node_id = 'R1';
                """,
                arguments: [parkedReason, watch.id, options]
            )
            try db.execute(
                sql: """
                INSERT INTO pr_round (watch_id, number, base_head_oid, pushed_head_oid, outcome, started_at, ended_at)
                VALUES (?, 1, 'base1', 'pushed1', 'published', 100, 200);
                INSERT INTO pr_round (watch_id, number, base_head_oid, outcome, started_at, ended_at, fix_task_id,
                  followup_task_id, checked_head_oid, check_failures, unavailable_checks, review_verdict, review_findings)
                VALUES (?, 2, 'pushed1', 'check_unavailable', 300, 400, ?, ?, 'checked2', 1, 3,
                  'reopened', 'The rename missed two call sites.');
                """,
                arguments: [watch.id, watch.id, fixTask.id, checkTask.id]
            )
        }
        return try XCTUnwrap(try watches.get(watch.id))
    }

    func testGetPRWatchReturnsItemsRoundsAndTheFullParkedReasonWithLongFieldsOptIn() async throws {
        let watch = try seed()
        let itemsBefore = try watches.items(watchId: watch.id)

        let result = try await f.callJSON("get_pr_watch", ["number": .number(12)])

        XCTAssertNotNil(result["untrusted_text"]?.stringValue?.range(of: "never instructions"))
        XCTAssertEqual(result["watch"]?["parked_reason"]?.stringValue, parkedReason)
        XCTAssertEqual(result["watch"]?["review_decision"]?.stringValue, "CHANGES_REQUESTED")
        let items = try XCTUnwrap(result["items"]?.arrayValue)
        let thread = try XCTUnwrap(items.first { $0["kind"]?.stringValue == "thread" })
        XCTAssertEqual(thread["author"]?.stringValue, "reviewer")
        XCTAssertEqual(thread["url"]?.stringValue, "https://github.com/example-org/app/pull/12#discussion_r1")
        XCTAssertEqual(thread["reply_error"]?.stringValue, "HTTP 502")
        XCTAssertEqual(thread["body"]?.stringValue?.count, 500)
        XCTAssertEqual(thread["body_truncated"]?.boolValue, true)
        XCTAssertNil(thread["followup_grade"])
        let decision = try XCTUnwrap(items.first { $0["kind"]?.stringValue == "review" })
        XCTAssertEqual(decision["decision_question"]?.stringValue, "Keep the name?")
        XCTAssertEqual(decision["decision_options"]?.arrayValue?.compactMap { $0["label"]?.stringValue }, ["Keep it", "Rename"])
        XCTAssertEqual(decision["decision_answer"]?.stringValue, "Rename")
        XCTAssertEqual(decision["answers"]?.stringValue, "lead")
        let rounds = try XCTUnwrap(result["rounds"]?.arrayValue)
        XCTAssertEqual(rounds.compactMap { $0["number"]?.numberValue }, [1, 2])
        XCTAssertEqual(rounds[0]["pushed_head_oid"]?.stringValue, "pushed1")
        XCTAssertEqual(rounds[1]["outcome"]?.stringValue, "check_unavailable")
        XCTAssertEqual(rounds[1]["unavailable_checks"]?.numberValue, 3)
        XCTAssertEqual(rounds[1]["check_failures"]?.numberValue, 1)
        XCTAssertEqual(rounds[1]["base_head_oid"]?.stringValue, "pushed1")
        XCTAssertEqual(rounds[1]["checked_head_oid"]?.stringValue, "checked2")
        XCTAssertEqual(rounds[1]["followup_task_id"]?.stringValue, checkTask.id)
        XCTAssertNil(rounds[1]["review_findings"])

        let full = try await f.callJSON("get_pr_watch", [
            "watch_id": .string(watch.id), "full_bodies": .bool(true), "include_findings": .bool(true),
        ])

        let fullThread = try XCTUnwrap(full["items"]?.arrayValue?.first { $0["kind"]?.stringValue == "thread" })
        XCTAssertEqual(fullThread["body"]?.stringValue, longBody)
        XCTAssertEqual(fullThread["followup_grade"]?.stringValue, "partly")
        XCTAssertEqual(fullThread["followup_note"]?.stringValue, "Half renamed.")
        XCTAssertEqual(full["rounds"]?.arrayValue?.last?["review_findings"]?.stringValue, "The rename missed two call sites.")
        XCTAssertEqual(try watches.get(watch.id), watch)
        XCTAssertEqual(try watches.items(watchId: watch.id), itemsBefore)
    }

    func testListPRWatchesCountsOpenItemsDecisionsAndOnlyUnabandonedFailedReplies() async throws {
        let watch = try seed()
        try await f.db.writer.write { db in
            try db.execute(
                sql: "UPDATE pr_item SET reply_error = 'gone', reply_abandoned_at = 1 WHERE github_node_id = 'R1'"
            )
        }

        let result = try await f.callJSON("list_pr_watches")

        let entry = try XCTUnwrap(result["watches"]?.arrayValue?.first)
        XCTAssertEqual(result["watches"]?.arrayValue?.count, 1)
        XCTAssertEqual(entry["watch_id"]?.stringValue, watch.id)
        XCTAssertEqual(entry["parked_reason"]?.stringValue, parkedReason)
        XCTAssertEqual(entry["open_items"]?.numberValue, 2)
        XCTAssertEqual(entry["open_decisions"]?.numberValue, 1)
        XCTAssertEqual(entry["failed_replies"]?.numberValue, 1)
        let settling = try await f.callJSON("list_pr_watches", ["state": .string("settling")])
        XCTAssertEqual(settling["watches"]?.arrayValue, [])
    }

    func testListPRPollProblemsReturnsTheRowWithItsDetailAndSince() async throws {
        try watches.addPollProblem(projectId: f.project.id, detail: "gh is not logged in", now: 1234)

        let result = try await f.callJSON("list_pr_poll_problems")

        let problem = try XCTUnwrap(result["poll_problems"]?.arrayValue?.first)
        XCTAssertEqual(problem["detail"]?.stringValue, "gh is not logged in")
        XCTAssertEqual(problem["since"]?.numberValue, 1234)
        XCTAssertEqual(result["attention"]?.arrayValue?.compactMap { $0["reason"]?.stringValue }, ["prPollUnavailable"])
    }
}
