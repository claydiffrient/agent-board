import AgentBoardCore
import AgentBoardServer
import XCTest
@testable import AgentBoardBridge

final class CommentDeliveryHookTests: XCTestCase {
    private var fixture: BridgeFixture!

    override func setUpWithError() throws {
        fixture = try BridgeFixture.make()
    }

    private func runningTask(_ title: String, sessionId: String) throws -> (BoardTask, TokenIdentity) {
        let task = try fixture.tasks.create(
            projectId: fixture.project.id, title: title, body: "Body.", acceptance: nil,
            priority: nil, column: .running, origin: .human, epicId: nil
        )
        _ = try fixture.session(sessionId, taskId: task.id)
        return (task, fixture.workerIdentity(sessionId: sessionId, taskId: task.id))
    }

    private func postToolUse(_ sessionId: String, _ identity: TokenIdentity) async -> HookDecision? {
        await fixture.hooks.handle(
            HookEvent(name: "PostToolUse", sessionId: sessionId, toolName: "Bash", rawJSON: "{}"), identity: identity
        )
    }

    private func utc(_ millis: Int64) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: millis.asDate)
    }

    func testAHumanCommentReachesTheLiveSessionOnItsNextToolCallOnce() async throws {
        let (task, identity) = try runningTask("Deliver comments", sessionId: "s-live")
        let (_, otherIdentity) = try runningTask("Somebody else's work", sessionId: "s-other")

        try fixture.board.addComment(
            projectId: fixture.project.id, taskId: task.id,
            author: CommentAuthor(kind: .orchestrator, sessionId: "orch-session", name: "Orchestrator"),
            body: "An agent's aside that must not be pushed."
        )
        let comment = try fixture.board.addComment(
            projectId: fixture.project.id, taskId: task.id, author: .human, body: "Use the queue table, not memory."
        )

        let delivered = await postToolUse("s-live", identity)
        let context = try XCTUnwrap(delivered?.additionalContext, "the live session got nothing")
        XCTAssertTrue(context.contains("Use the queue table, not memory."), context)
        XCTAssertTrue(context.contains("from the human"), context)
        XCTAssertTrue(context.contains(utc(comment.createdAt)), context)
        XCTAssertFalse(context.contains("An agent's aside"), context)
        let body = try XCTUnwrap(delivered).responseBody(hookEventName: "PostToolUse")
        XCTAssertNil(body["decision"])

        let again = await postToolUse("s-live", identity)
        XCTAssertNil(again, "the comment was delivered twice")

        let other = await postToolUse("s-other", otherIdentity)
        XCTAssertNil(other, "a session on another task got the comment")
    }

    func testCommentsBeforeOneToolCallArriveTogetherWithinTheHookCap() async throws {
        let (task, identity) = try runningTask("Batch comments", sessionId: "s-batch")
        let long = String(repeating: "x", count: TaskComment.maxBodyLength)
        for body in ["First remark.", "Second remark.", long] {
            try fixture.board.addComment(projectId: fixture.project.id, taskId: task.id, author: .human, body: body)
        }

        let first = await postToolUse("s-batch", identity)
        let batch = try XCTUnwrap(first?.additionalContext)
        XCTAssertLessThanOrEqual(batch.count, 10_000)
        XCTAssertTrue(batch.contains("First remark."), batch)
        XCTAssertTrue(batch.contains("Second remark."), batch)
        XCTAssertLessThan(try XCTUnwrap(batch.range(of: "First remark.")).lowerBound,
                          try XCTUnwrap(batch.range(of: "Second remark.")).lowerBound)

        let second = await postToolUse("s-batch", identity)
        let overflow = try XCTUnwrap(second?.additionalContext, "the comment that did not fit was dropped")
        XCTAssertLessThanOrEqual(overflow.count, 10_000)
        XCTAssertTrue(overflow.contains("cut short here"), overflow)

        let third = await postToolUse("s-batch", identity)
        XCTAssertNil(third)
    }

    func testACommentQueuedDuringSetupFollowsTheSessionToItsRealId() async throws {
        let task = try fixture.tasks.create(
            projectId: fixture.project.id, title: "Setup", body: "Body.", acceptance: nil,
            priority: nil, column: .running, origin: .human, epicId: nil
        )
        _ = try fixture.session("placeholder", state: .setup, taskId: task.id)
        try fixture.board.addComment(projectId: fixture.project.id, taskId: task.id, author: .human, body: "Said during setup.")

        _ = try fixture.sessions.promoteSetupSession("placeholder", to: "s-real", shortId: nil)
        let delivered = await postToolUse("s-real", fixture.workerIdentity(sessionId: "s-real", taskId: task.id))

        XCTAssertTrue(try XCTUnwrap(delivered?.additionalContext).contains("Said during setup."))
    }

    /// SPEC §2: `/clear` sends `SessionEnd` with `reason: "clear"` for the old id, then the new id's first hook.
    func testACommentQueuedBeforeAClearReachesTheForkedSession() async throws {
        let (task, identity) = try runningTask("Clear", sessionId: "s-before")
        try fixture.board.addComment(projectId: fixture.project.id, taskId: task.id, author: .human, body: "Said before the clear.")

        _ = await fixture.hooks.handle(
            HookEvent(name: "SessionEnd", sessionId: "s-before", sessionEndReason: "clear", rawJSON: "{\"reason\":\"clear\"}"),
            identity: identity
        )
        _ = await fixture.hooks.handle(
            HookEvent(name: "SessionStart", sessionId: "s-after", sessionSource: "clear", rawJSON: "{\"source\":\"clear\"}"),
            identity: identity
        )
        let delivered = await postToolUse("s-after", identity)

        XCTAssertTrue(try XCTUnwrap(delivered?.additionalContext, "the forked session got nothing").contains("Said before the clear."))
        XCTAssertNil(try CommentStore(fixture.db).takeDelivery(sessionId: "s-before"))
    }

    func testASessionThatEndsDropsWhatWasQueuedForIt() async throws {
        let (task, identity) = try runningTask("Ended", sessionId: "s-ended")
        try fixture.board.addComment(projectId: fixture.project.id, taskId: task.id, author: .human, body: "Too late.")

        _ = await fixture.hooks.handle(HookEvent(name: "SessionEnd", sessionId: "s-ended", rawJSON: "{}"), identity: identity)
        let after = await postToolUse("s-ended", identity)

        XCTAssertNil(after)
        XCTAssertEqual(try CommentStore(fixture.db).list(taskId: task.id).map(\.body), ["Too late."])
    }
}
