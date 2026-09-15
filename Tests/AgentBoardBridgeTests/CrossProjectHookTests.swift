import AgentBoardBridge
import AgentBoardCore
import AgentBoardServer
import Foundation
import XCTest

/// The hook endpoint takes a session id from the payload and a grant from the query string, so it is
/// the one surface where a caller names something the tool layer would never let it name. A grant for
/// one project must not reach another project's session through it.
final class CrossProjectHookTests: XCTestCase {
    private var f: BridgeFixture!
    private var other: Project!
    private var theirTask: BoardTask!
    private let theirSession = "w-theirs"

    override func setUpWithError() throws {
        f = try BridgeFixture.make()
        other = try f.otherProject()
        theirTask = try f.task("theirs", column: .running, in: other.id)
        try f.sessions.insert(AgentSession(
            sessionId: theirSession, projectId: other.id, taskId: theirTask.id,
            role: .worker, cwd: "/tmp/theirs", state: .running
        ))
        try f.tasks.setBlocked(theirTask.id, true, reason: "waiting on a human over there")
    }

    override func tearDown() {
        f = nil
        other = nil
        theirTask = nil
    }

    private func assertTheirBoardIsUntouched(file: StaticString = #filePath, line: UInt = #line) throws {
        let session = try XCTUnwrap(f.sessions.get(theirSession), file: file, line: line)
        XCTAssertEqual(session.state, .running, "their session's state was changed", file: file, line: line)
        XCTAssertNil(session.transcriptPath, "their session's transcript path was overwritten", file: file, line: line)
        XCTAssertNil(session.stopReason, "their session's stop reason was overwritten", file: file, line: line)
        XCTAssertEqual(try f.tasks.get(theirTask.id)?.blocked, true, "their task was unblocked", file: file, line: line)
        XCTAssertEqual(
            try f.progress.list(taskId: theirTask.id).count, 0,
            "a progress row landed on their task", file: file, line: line
        )
        XCTAssertEqual(
            try f.reports.unconsumed(projectId: other.id).count, 0,
            "a report landed on their queue", file: file, line: line
        )
    }

    func testAnOrchestratorsHooksCannotDriveAnotherProjectsSession() async throws {
        let identity = f.orchestratorIdentity
        try f.session(try XCTUnwrap(identity.sessionId), role: .orchestrator)

        for name in ["SessionStart", "PostToolUse", "Stop", "SessionEnd"] {
            _ = await f.hook(name, sessionId: theirSession, identity: identity, lastAssistantMessage: "seized")
        }
        try assertTheirBoardIsUntouched()

        let events = await f.events.events
        XCTAssertEqual(events, [], "a hook naming their session woke something on their board")
    }

    func testANotificationHookCannotBlockAnotherProjectsTask() async throws {
        let event = HookEvent(
            name: "Notification", sessionId: theirSession, notificationType: "permission_prompt",
            notificationMessage: "approve this", rawJSON: "{}"
        )
        _ = await f.hooks.handle(event, identity: f.orchestratorIdentity)

        try assertTheirBoardIsUntouched()
    }

    func testABlockedPushByOneProjectsWorkerIsNotLoggedOnAnotherProjectsTask() async throws {
        let mine = try f.task("mine", column: .running)
        _ = try f.workerSession("w-mine", taskId: mine.id)
        let worker = f.workerIdentity(sessionId: "w-mine", taskId: mine.id)

        let decision = await f.preToolUse("git " + "push origin HEAD", sessionId: theirSession, identity: worker)

        XCTAssertEqual(decision?.permissionDecision, "deny", "the integration guard must still fire")
        try assertTheirBoardIsUntouched()
        XCTAssertEqual(try f.progress.list(taskId: mine.id).count, 1, "the block belongs on the caller's own task")
    }

    func testAWindDownOrderIsNotDeliveredThroughAnotherProjectsSession() async throws {
        let mine = try f.task("mine", column: .running)
        _ = try f.workerSession("w-mine", taskId: mine.id)
        let worker = f.workerIdentity(sessionId: "w-mine", taskId: mine.id)
        try f.board.requestShutdown(projectId: f.project.id, requestedBy: "human", reason: "spend")

        _ = await f.preToolUse("swift build", sessionId: theirSession, identity: worker)

        try assertTheirBoardIsUntouched()
    }

    func testAGrantCannotBindItselfToAnotherProjectsSession() async throws {
        let grant = try TokenGrantStore(f.db).issue(projectId: f.project.id, scope: .orchestrator, taskId: nil)
        let unbound = TokenIdentity(
            token: grant.token, scope: .orchestrator, projectId: f.project.id, sessionId: nil
        )

        _ = await f.hook("SessionStart", sessionId: theirSession, identity: unbound)

        let rebound = try XCTUnwrap(TokenGrantStore(f.db).resolve(token: grant.token))
        XCTAssertNil(rebound.sessionId, "the grant bound itself to another project's session")
        try assertTheirBoardIsUntouched()
    }

    func testTheSameHooksStillDriveTheCallersOwnSession() async throws {
        let mine = try f.task("mine", column: .running)
        _ = try f.workerSession("w-mine", taskId: mine.id)
        try f.tasks.setBlocked(mine.id, true, reason: "waiting")
        let worker = f.workerIdentity(sessionId: "w-mine", taskId: mine.id)

        let event = HookEvent(name: "PostToolUse", sessionId: "w-mine", toolName: "Bash", rawJSON: "{}")
        _ = await f.hooks.handle(event, identity: worker)

        XCTAssertEqual(try f.tasks.get(mine.id)?.blocked, false, "the scoping guard broke the ordinary path")
        XCTAssertEqual(try f.progress.list(taskId: mine.id).map(\.text), ["Bash"])
    }
}
