import Foundation
import XCTest
@testable import AgentBoardCore

/// SPEC §15.5: the board enforces a ruling in code, not through the prompt.
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
