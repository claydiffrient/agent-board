import Foundation
import XCTest
@testable import AgentBoardCore

/// SPEC §15.6: the board enforces a ruling in code, not through the prompt.
final class RulingEnforcementTests: XCTestCase {
    func testAPushReRequestedAtTheDeniedCommitIsRefusedAndOneAtANewCommitIsNot() throws {
        let f = try Fixture.make()
        let denied = String(repeating: "a", count: 40)
        func request(_ head: String) throws -> Approval {
            try f.board.requestPublish(
                projectId: f.project.id, kind: .push,
                request: PublishRequest(branch: "agentboard/feature", headOid: head), requestedBy: "orch"
            )
        }
        let first = try request(denied)
        try f.board.denyApproval(first.id, reason: "The migration is not reversible.")

        XCTAssertThrowsError(try request(denied)) {
            let refusal = $0 as? RulingRefusal
            XCTAssertTrue(refusal?.reason.contains("The migration is not reversible.") == true, "\($0)")
        }
        let next = try request(String(repeating: "b", count: 40))
        XCTAssertNotEqual(next.id, first.id)
        XCTAssertTrue(next.isPending)
    }

    func testADeniedSpawnIsRefusedUntilTheTaskIsEdited() throws {
        let f = try Fixture.make()
        let task = try f.task("Wire the thing", column: .ready)
        guard case .approvalPending(let first) = try f.board.requestSpawn(taskId: task.id, requestedBy: "orch") else {
            return XCTFail("autonomy off should queue a spawn approval")
        }
        try f.board.denyApproval(first.id, reason: "Not until the schema lands.")

        guard case .refused(let reason) = try f.board.requestSpawn(taskId: task.id, requestedBy: "orch") else {
            return XCTFail("an unchanged task was spawnable after a deny")
        }
        XCTAssertTrue(reason.contains("lapses once the task changes"), reason)

        var edited = try XCTUnwrap(f.tasks.get(task.id))
        edited.body = "Wait for the schema task, then wire the thing."
        try f.tasks.update(edited)

        guard case .approvalPending(let next) = try f.board.requestSpawn(taskId: task.id, requestedBy: "orch") else {
            return XCTFail("the deny outlived an edit to the task body")
        }
        XCTAssertNotEqual(next.id, first.id)
        XCTAssertTrue(next.isPending)
    }

    func testADeniedIntegrationIsRefusedUntilAnotherTaskInTheEpicIsAccepted() throws {
        let f = try Fixture.make()
        let (epic, _) = try f.board.createEpic(projectId: f.project.id, title: "Ship it", goal: nil, tasks: [])
        func epicTask(_ title: String) throws -> BoardTask {
            try f.tasks.create(
                projectId: f.project.id, title: title, body: nil, acceptance: nil, priority: nil,
                column: .review, origin: .orchestrator, epicId: epic.id
            )
        }
        let done = try epicTask("First")
        let pending = try epicTask("Second")
        try f.board.accept(taskId: done.id)
        try f.db.writer.write {
            try $0.execute(sql: "UPDATE task SET created_at = created_at - 10000, done_at = done_at - 10000")
        }
        let first = try f.board.requestIntegration(epicId: epic.id, requestedBy: "orch", epicTip: "abc")
        try f.board.denyApproval(first.id, reason: "Finish the second task first.")

        XCTAssertThrowsError(try f.board.requestIntegration(epicId: epic.id, requestedBy: "orch", epicTip: "abc")) {
            let reason = ($0 as? RulingRefusal)?.reason ?? "\($0)"
            XCTAssertTrue(reason.contains("lapses once a task in the epic is accepted"), reason)
        }

        try f.board.accept(taskId: pending.id)

        let next = try f.board.requestIntegration(epicId: epic.id, requestedBy: "orch", epicTip: "abc")
        XCTAssertNotEqual(next.id, first.id)
        XCTAssertTrue(next.isPending)
    }

    func testAHoldOnTheCurrentBlockRefusesASpawn() throws {
        let f = try Fixture.make()
        let task = try f.task("Wire the thing", column: .running)
        try f.sessions.insert(f.session("w-hold", state: .running, taskId: task.id))
        _ = try f.board.blockOnFileLock(taskId: task.id, sessionId: "w-hold", reason: "Waiting on a file")
        let blocked = try XCTUnwrap(f.tasks.get(task.id))
        XCTAssertEqual(blocked.column, .ready)
        try RulingStore(f.db).record(
            .task(task.id), question: "Waiting on a file", questionAt: try XCTUnwrap(blocked.blockedAt),
            verdict: .hold, note: "Leave it until the schema lands."
        )

        guard case .refused(let reason) = try f.board.requestSpawn(taskId: task.id, requestedBy: "orch") else {
            return XCTFail("a held task was spawnable")
        }
        XCTAssertTrue(reason.contains("Leave it until the schema lands."), reason)
    }

    func testASpawnPromptPutsTheRulingsAboveTheTaskBodyAndTheCommentThread() throws {
        let f = try Fixture.make()
        let task = try f.task("Wire the thing", column: .ready)
        let comment = try CommentStore(f.db).add(taskId: task.id, author: .human, body: "Prefer the small fix.")
        let ruling = try RulingStore(f.db).record(
            .task(task.id), question: "Should I rewrite the parser?", questionAt: 1,
            verdict: .instead, note: "Patch the tokenizer only."
        )

        let prompt = OpeningPrompt.compose(
            task: task, branch: "agentboard/\(task.id)", attempt: 1, comments: [comment], rulings: [ruling]
        )

        let rulings = try XCTUnwrap(prompt.range(of: "Patch the tokenizer only."))
        let body = try XCTUnwrap(prompt.range(of: "# Task: Wire the thing"))
        let thread = try XCTUnwrap(prompt.range(of: "Prefer the small fix."))
        XCTAssertLessThan(rulings.lowerBound, body.lowerBound)
        XCTAssertLessThan(body.lowerBound, thread.lowerBound)
    }
}
