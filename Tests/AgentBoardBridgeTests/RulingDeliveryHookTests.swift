import AgentBoardCore
import AgentBoardServer
import XCTest
@testable import AgentBoardBridge

/// SPEC §15.8: a session still making tool calls gets a ruling through `PostToolUse`, once.
final class RulingDeliveryHookTests: XCTestCase {
    func testARulingReachesTheBusySessionOnItsNextToolCallOnce() async throws {
        let fixture = try BridgeFixture.make()
        let task = try fixture.tasks.create(
            projectId: fixture.project.id, title: "Busy work", body: "Body.", acceptance: nil,
            priority: nil, column: .running, origin: .human, epicId: nil
        )
        _ = try fixture.session("s-busy", taskId: task.id)
        let identity = fixture.workerIdentity(sessionId: "s-busy", taskId: task.id)
        try RulingStore(fixture.db).record(
            .task(task.id), question: "Which table?", questionAt: .nowMillis, verdict: .instead,
            note: "Use the queue table."
        )
        let event = HookEvent(name: "PostToolUse", sessionId: "s-busy", toolName: "Bash", rawJSON: "{}")

        let delivered = await fixture.hooks.handle(event, identity: identity)
        let context = try XCTUnwrap(delivered?.additionalContext, "the busy session got nothing")
        XCTAssertTrue(context.contains("Use the queue table."), context)

        let again = await fixture.hooks.handle(event, identity: identity)
        XCTAssertNil(again, "the ruling was delivered twice")
    }
}
