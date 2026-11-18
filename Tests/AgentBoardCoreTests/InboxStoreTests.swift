import Foundation
import GRDB
import XCTest
@testable import AgentBoardCore

final class InboxStoreTests: XCTestCase {
    func testAHoldRulingTakesABlockedTaskOutWhileItStaysBlockedAndASecondBlockBringsItBack() throws {
        let f = try Fixture.make()
        let inbox = InboxStore(f.db)
        let task = try f.task("Wire the thing", column: .running)
        try f.sessions.insert(f.session("w-block", state: .running, taskId: task.id))
        _ = try f.board.block(taskId: task.id, sessionId: "w-block", reason: "May I drop the cache?", source: .worker)

        let asked = try XCTUnwrap(try inbox.items().first)
        XCTAssertEqual(asked.kind, .blockedTask)
        XCTAssertEqual(asked.subject, .task(task.id))
        XCTAssertEqual(asked.question, "May I drop the cache?")
        try RulingStore(f.db).record(
            .task(task.id), question: "May I drop the cache?", questionAt: asked.questionAt, verdict: .hold, note: "Not yet"
        )

        XCTAssertEqual(try inbox.items(), [])
        XCTAssertEqual(try inbox.count(), 0)
        XCTAssertEqual(try f.tasks.get(task.id)?.blocked, true)

        _ = try f.board.block(taskId: task.id, sessionId: "w-block", reason: "And now?", source: .worker)
        XCTAssertEqual(try inbox.items().map(\.question), ["And now?"])
        XCTAssertEqual(try inbox.count(), 1)
    }

    /// SPEC §15.5: a capped review stays in the inbox until every finding of its latest round is ruled,
    /// and leaves once one of those rulings is an overrule.
    func testOverrulingACappedTasksFindingsAnswersItsReviewEpisode() throws {
        let f = try Fixture.make()
        var settings = f.project.settings
        settings.reviewRoundCap = 1
        try f.projects.updateSettings(f.project.id, settings)
        let inbox = InboxStore(f.db)
        let task = try f.task("Wire the thing", column: .review)
        try f.sessions.insert(f.session("rev-1", taskId: task.id))
        let reopen = try f.board.reviewReopen(
            taskId: task.id, sessionId: "rev-1", reviewerName: "Rowan", findings: ["Empty input throws.", "Rename it."]
        )
        XCTAssertTrue(reopen.capped)
        let row = try XCTUnwrap(try inbox.items().first)
        XCTAssertEqual(row.kind, .humanReview)
        let rulings = RulingStore(f.db)
        func rule(_ n: Int, _ verdict: RulingVerdict) throws {
            try rulings.record(
                .reviewFinding(taskId: task.id, ref: ReviewRound.findingRef(round: 1, finding: n)),
                question: "finding \(n)", questionAt: row.questionAt, verdict: verdict,
                note: verdict == .overrule ? "Not needed." : nil
            )
        }

        try rule(1, .overrule)
        XCTAssertEqual(try inbox.items().map(\.id), [row.id], "one finding is still unruled")

        try rule(2, .uphold)
        XCTAssertEqual(try inbox.items(), [])
        XCTAssertEqual(try f.tasks.get(task.id)?.column, .review)
    }

    func testAReviewHeldByAnAgentAndACoordinatorRequestNeverAppear() throws {
        let f = try Fixture.make()
        let inbox = InboxStore(f.db)
        let reviewer = try RosterStore(f.db).create(name: "Rita", role: "reviewer", systemPrompt: "Review.")
        let task = try f.task("Wire the thing", column: .review)
        try f.tasks.setReviewer(task.id, reviewer.id)
        var session = f.session("r-1", state: .running, taskId: task.id)
        session.rosterAgentId = reviewer.id
        try f.sessions.insert(session)
        _ = try RequestStore(f.db).send(toProjectId: f.project.id, body: "Please ship the widget", planNoteId: nil)

        XCTAssertEqual(try inbox.items(), [])

        try f.sessions.setState("r-1", .idle)
        XCTAssertEqual(try inbox.items().map(\.kind), [.reviewerStopped])
    }

    func testEachSurfaceWaitsUntilItsOwnEpisodeIsRuled() throws {
        let f = try Fixture.make()
        let inbox = InboxStore(f.db)
        var settings = f.project.settings
        settings.prFollowThrough.enabled = true
        try f.projects.updateSettings(f.project.id, settings)

        let pushing = try f.task("Pushing", column: .review)
        let approval = try ApprovalStore(f.db).create(
            projectId: f.project.id, kind: .push, taskId: pushing.id, epicId: nil, requestedBy: "orch", reason: "Ship it"
        )
        try f.db.writer.write { db in try Board.leaveReviewToPerson(db, taskId: pushing.id, reason: "Protected path") }
        let proposal = try f.task("Idea", column: .proposed, origin: .workerProposal)
        try f.db.writer.write { db in
            try db.execute(sql: """
                INSERT INTO pr_watch (id, project_id, repo_owner, repo_name, number, url, title, head_ref, head_oid,
                  base_ref, state, parked_reason, parked_at, created_at, updated_at)
                VALUES ('w1', ?, 'octo', 'example', 1, 'u', 'Widget', 'h', 'oid', 'main', 'parked', 'Round cap', 500, 0, 0);
                INSERT INTO pr_item (id, watch_id, github_node_id, kind, body, state, verdict, decision_question,
                  decision_notified_at, created_at, updated_at)
                VALUES (7, 'w1', 'n1', 'thread', 'Rename?', 'open', 'decision', 'Rename it?', 400, 50, 400);
                """, arguments: [f.project.id])
        }
        let other = try f.otherProject()
        _ = try ApprovalStore(f.db).create(
            projectId: other.id, kind: .spawn, taskId: nil, epicId: nil, requestedBy: "orch", reason: nil
        )

        let items = try inbox.items(projectId: f.project.id)
        XCTAssertEqual(
            Set(items.map(\.id)),
            ["approval:\(approval.id)", "human_review:\(pushing.id)", "proposal:\(proposal.id)", "pr_decision:7", "parked_watch:w1"]
        )
        XCTAssertEqual(try inbox.count(), 6)

        let rulings = RulingStore(f.db)
        try rulings.record(.approval(approval.id), question: "Ship it", questionAt: 0, verdict: .deny, note: "No")
        try rulings.record(.task(pushing.id), question: "q", questionAt: 0, verdict: .reopen, note: "Earlier episode")
        try rulings.record(.prItem(7), question: "Rename it?", questionAt: 400, verdict: .reply)
        try rulings.record(.prWatch("w1"), question: "Round cap", questionAt: 500, verdict: .keepParked)
        XCTAssertEqual(
            Set(try inbox.items(projectId: f.project.id).map(\.id)),
            ["human_review:\(pushing.id)", "proposal:\(proposal.id)"]
        )

        settings.autonomyEnabled = true
        try f.projects.updateSettings(f.project.id, settings)
        XCTAssertEqual(try inbox.items(projectId: f.project.id).map(\.id), ["human_review:\(pushing.id)"])
    }
}
