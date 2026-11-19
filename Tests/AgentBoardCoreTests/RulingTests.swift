import Foundation
import GRDB
import XCTest
@testable import AgentBoardCore

final class RulingTests: XCTestCase {
    func testTheTableRefusesAnUpdateAndARowNamingTwoSubjects() throws {
        let f = try Fixture.make()
        let task = try f.task("Wire the thing", column: .running)
        let ruling = try RulingStore(f.db).record(
            .task(task.id), question: "May I drop the cache?", questionAt: 1, verdict: .hold, note: "Not yet"
        )

        try f.db.writer.write { db in
            XCTAssertThrowsError(try db.execute(sql: "UPDATE ruling SET note = 'changed' WHERE id = ?", arguments: [ruling.id])) {
                XCTAssertTrue("\($0)".contains("rulings are append-only"), "\($0)")
            }
            try db.execute(sql: """
                INSERT INTO pr_watch (id, project_id, repo_owner, repo_name, number, url, title, head_ref, head_oid,
                  base_ref, state, created_at, updated_at)
                VALUES ('w', ?, 'octo', 'example', 1, 'u', 't', 'h', 'oid', 'main', 'watching', 0, 0)
                """, arguments: [f.project.id])
            XCTAssertThrowsError(try db.execute(
                sql: """
                INSERT INTO ruling (id, project_id, subject_kind, task_id, pr_watch_id, question, question_at, verdict, answered_at)
                VALUES ('two', ?, 'task', ?, 'w', 'q', 1, 'proceed', 1)
                """,
                arguments: [f.project.id, task.id]
            )) { XCTAssertTrue("\($0)".contains("CHECK constraint failed"), "\($0)") }
        }
        XCTAssertEqual(try RulingStore(f.db).history(.task(task.id)), [ruling])
    }

    func testASecondBlockAdvancesBlockedAt() throws {
        let f = try Fixture.make()
        let task = try f.task("Wire the thing", column: .running)
        try f.sessions.insert(f.session("w-block", state: .running, taskId: task.id))

        _ = try f.board.block(taskId: task.id, sessionId: "w-block", reason: "first", source: .worker)
        let first = try XCTUnwrap(try f.tasks.get(task.id)?.blockedAt)
        try f.board.unblock(taskId: task.id, sessionId: "w-block")
        _ = try f.board.block(taskId: task.id, sessionId: "w-block", reason: "second", source: .worker)

        XCTAssertGreaterThan(try XCTUnwrap(try f.tasks.get(task.id)?.blockedAt), first)
    }

    func testEveryVerdictThatNeedsANoteIsRefusedWithoutOne() throws {
        let f = try Fixture.make()
        let task = try f.task("Wire the thing", column: .review)
        let approval = try f.approvals.create(
            projectId: f.project.id, kind: .push, taskId: task.id, epicId: nil, requestedBy: "orch", reason: nil
        )
        let store = RulingStore(f.db)
        let required: [(RulingVerdict, RulingSubject)] = [
            (.instead, .task(task.id)), (.hold, .task(task.id)), (.reopen, .task(task.id)),
            (.deny, .approval(approval.id)), (.overrule, .reviewFinding(taskId: task.id, ref: "1:1")),
        ]
        for (verdict, subject) in required {
            XCTAssertThrowsError(try store.record(subject, question: "q", questionAt: 1, verdict: verdict, note: "  ")) {
                XCTAssertEqual($0 as? RulingError, .noteRequired(verdict))
            }
            XCTAssertNoThrow(try store.record(subject, question: "q", questionAt: 1, verdict: verdict, note: "because"))
        }
        XCTAssertNoThrow(try store.record(.task(task.id), question: "q", questionAt: 2, verdict: .proceed))
    }

    func testStandingDropsWhatALaterRulingSupersedes() throws {
        let f = try Fixture.make()
        let task = try f.task("Wire the thing", column: .running)
        let other = try f.task("Other", column: .running)
        let store = RulingStore(f.db)
        let held = try store.record(.task(task.id), question: "q1", questionAt: 1, verdict: .hold, note: "wait", now: 10)
        let proceeded = try store.record(.task(task.id), question: "q2", questionAt: 2, verdict: .proceed, now: 20)
        let lifted = try store.record(
            .task(task.id), question: "q1", questionAt: 1, verdict: .proceed, supersedes: held.id, now: 30
        )

        XCTAssertEqual(try store.standing(.task(task.id)).map(\.id), [lifted.id, proceeded.id])
        XCTAssertEqual(try store.history(.task(task.id)).map(\.id), [lifted.id, proceeded.id, held.id])
        XCTAssertThrowsError(try store.record(
            .task(task.id), question: "q1", questionAt: 1, verdict: .proceed, supersedes: held.id
        )) { XCTAssertEqual($0 as? RulingError, .alreadySuperseded(held.id)) }
        XCTAssertThrowsError(try store.record(
            .task(other.id), question: "q", questionAt: 1, verdict: .proceed, supersedes: proceeded.id
        )) { XCTAssertEqual($0 as? RulingError, .supersedesAnotherSubject(proceeded.id)) }
    }

    func testTheMigrationCarriesTheHumansDecisionAnswersAndDismissalsIntoRulings() throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: configuration)
        try AppDatabase.migrator.migrate(queue, upTo: "note_archived_at")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO project (id, name, repo_path, worktree_root, settings_json, created_at)
                VALUES ('p1', 'p1', '/repo/p1', '/w', '{}', 0);
                INSERT INTO pr_watch (id, project_id, repo_owner, repo_name, number, url, title, head_ref, head_oid,
                  base_ref, state, created_at, updated_at)
                VALUES ('w1', 'p1', 'octo', 'example', 1, 'u', 't', 'h', 'oid', 'main', 'watching', 0, 0);
                INSERT INTO pr_item (id, watch_id, github_node_id, kind, body, state, verdict, decision_question,
                  decision_options_json, decision_answer, decision_notified_at, created_at, updated_at)
                VALUES
                  (1, 'w1', 'n1', 'thread', 'Rename?', 'open', 'fix', 'Rename it?',
                   '[{"label":"Rename it","verdict":"fix"}]', 'Rename it', 100, 50, 200),
                  (2, 'w1', 'n2', 'thread', 'Why?', 'handled', 'answer', 'Explain?',
                   '[{"label":"Rename it","verdict":"fix"}]', 'Because the API says so', 110, 50, 210);
                INSERT INTO pr_item (id, watch_id, github_node_id, kind, body, state, dismiss_reason, dismissed_by,
                  dismissed_at, created_at, updated_at)
                VALUES
                  (3, 'w1', 'n3', 'thread', 'Nit', 'dismissed', 'Out of scope', 'human', 300, 60, 300),
                  (4, 'w1', 'n4', 'thread', 'Nit 2', 'dismissed', 'Agent text', 'orchestrator (s1), approval a1', 310, 60, 310);
                """)
        }

        try AppDatabase.migrator.migrate(queue)

        let rulings = try queue.read { try Ruling.fetchAll($0, sql: "SELECT * FROM ruling ORDER BY pr_item_id") }
        XCTAssertEqual(rulings.map(\.prItemId), [1, 2, 3])
        XCTAssertEqual(rulings.map(\.verdict), [.choose, .reply, .dismiss])
        XCTAssertEqual(rulings.map(\.choice), ["Rename it", nil, nil])
        XCTAssertEqual(rulings.map(\.note), [nil, "Because the API says so", "Out of scope"])
        XCTAssertEqual(rulings.map(\.question), ["Rename it?", "Explain?", "Nit"])
        XCTAssertEqual(rulings.map(\.questionAt), [100, 110, 60])
        XCTAssertEqual(rulings.map(\.projectId), ["p1", "p1", "p1"])
    }
}
