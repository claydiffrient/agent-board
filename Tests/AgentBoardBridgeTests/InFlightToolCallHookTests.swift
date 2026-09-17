import AgentBoardBridge
import AgentBoardCore
import AgentBoardServer
import Foundation
import XCTest

/// `PreToolUse` is what tells Agent Board a tool call has started; `PostToolUse` fires only when it
/// returns. These pin what each writes to the session row, because every deadline downstream reads
/// those two columns.
final class InFlightToolCallHookTests: XCTestCase {
    private var f: BridgeFixture!
    private var identity: TokenIdentity!

    override func setUpWithError() throws {
        f = try BridgeFixture.make()
        let task = try f.task("Build it", column: .running)
        try f.session("w1", taskId: task.id)
        identity = f.workerIdentity(sessionId: "w1", taskId: task.id)
    }

    private func session() throws -> AgentSession {
        try XCTUnwrap(f.sessions.get("w1"))
    }

    private func post(_ tool: String = "Bash") async {
        _ = await f.hooks.handle(
            HookEvent(name: "PostToolUse", sessionId: "w1", toolName: tool, rawJSON: "{}"),
            identity: identity
        )
    }

    func testPreToolUseMarksTheCallInFlightAndCountsAsActivity() async throws {
        XCTAssertNil(try session().toolStartedAt)

        _ = await f.preToolUse("swift build", sessionId: "w1", identity: identity)

        let row = try session()
        XCTAssertNotNil(row.toolStartedAt)
        XCTAssertEqual(row.toolsInFlight, 1)
        XCTAssertEqual(row.lastTool, "Bash")
        XCTAssertNotNil(row.lastActivity)
    }

    func testPostToolUseClearsIt() async throws {
        _ = await f.preToolUse("swift build", sessionId: "w1", identity: identity)

        await post()

        let row = try session()
        XCTAssertNil(row.toolStartedAt)
        XCTAssertEqual(row.toolsInFlight, 0)
    }

    /// Claude emits several `tool_use` blocks in one message and they run at once, so a short call
    /// finishing must not end a long one's grace. The row keeps the *oldest* outstanding start.
    func testAShortParallelCallFinishingLeavesTheLongOneInFlight() async throws {
        _ = await f.preToolUse("swift build", sessionId: "w1", identity: identity)
        let started = try XCTUnwrap(session().toolStartedAt)
        _ = await f.preToolUse("git status", sessionId: "w1", identity: identity)

        await post()

        let row = try session()
        XCTAssertEqual(row.toolStartedAt, started, "the second call's start replaced the first's")
        XCTAssertEqual(row.toolsInFlight, 1)
    }

    /// The turn boundary is the reset that bounds a leak: when the model has stopped, nothing it
    /// launched is still running, whatever `PostToolUse` went missing.
    func testStopClearsACallWhosePostToolUseNeverArrived() async throws {
        _ = await f.preToolUse("swift build", sessionId: "w1", identity: identity)

        await f.hook("Stop", sessionId: "w1", identity: identity)

        XCTAssertNil(try session().toolStartedAt)
        XCTAssertEqual(try session().toolsInFlight, 0)
    }

    func testSessionEndClearsItToo() async throws {
        _ = await f.preToolUse("swift build", sessionId: "w1", identity: identity)

        await f.hook("SessionEnd", sessionId: "w1", identity: identity)

        XCTAssertNil(try session().toolStartedAt)
    }

    /// A denied call never runs, so it may not buy the session a grace window it is not using.
    func testADeniedCallIsNotInFlight() async throws {
        let decision = await f.preToolUse("git push origin HEAD", sessionId: "w1", identity: identity)

        XCTAssertNotNil(decision)
        XCTAssertNil(try session().toolStartedAt)
        XCTAssertEqual(try session().toolsInFlight, 0)
    }

    /// Another project's grant naming this session must not be able to write its clock.
    func testAForeignGrantCannotMarkACallInFlight() async throws {
        let other = try f.projects.register(
            name: "Other", repoPath: "/other", baseBranch: "main", worktreeRoot: "/w", memoryDir: nil
        )
        let foreign = TokenIdentity(
            token: "x", scope: .worker, projectId: other.id, sessionId: "w1", taskId: nil
        )

        _ = await f.preToolUse("swift build", sessionId: "w1", identity: foreign)

        XCTAssertNil(try session().toolStartedAt)
    }
}
