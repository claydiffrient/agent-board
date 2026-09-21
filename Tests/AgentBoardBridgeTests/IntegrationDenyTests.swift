import AgentBoardBridge
import AgentBoardCore
import AgentBoardServer
import Foundation
import XCTest

final class IntegrationDenyTests: XCTestCase {
    private var f: BridgeFixture!
    private var task: BoardTask!
    private var identity: TokenIdentity!

    override func setUpWithError() throws {
        f = try BridgeFixture.make()
        task = try f.task("t", column: .running)
        try f.session("w1", taskId: task.id)
        identity = f.workerIdentity(sessionId: "w1", taskId: task.id)
    }

    func testPushIsDeniedAndRecorded() async throws {
        let decision = await f.preToolUse("git push -u origin HEAD", sessionId: "w1", identity: identity)
        XCTAssertEqual(decision?.permissionDecision, "deny")
        XCTAssertEqual(decision?.reason, IntegrationGuard.Violation.push.reason)

        let entry = try XCTUnwrap(f.progress.latest(taskId: task.id))
        XCTAssertEqual(entry.kind, .error)
        XCTAssertEqual(entry.sessionId, "w1")
        XCTAssertTrue(entry.text.contains("push"), entry.text)
        XCTAssertTrue(entry.text.contains("git push -u origin HEAD"), entry.text)
    }

    func testPullRequestCreateAndMergeAreDenied() async throws {
        let create = await f.preToolUse("gh pr create --draft", sessionId: "w1", identity: identity)
        XCTAssertEqual(create?.reason, IntegrationGuard.Violation.pullRequestCreate.reason)

        let merge = await f.preToolUse("gh pr merge 42 --squash", sessionId: "w1", identity: identity)
        XCTAssertEqual(merge?.reason, IntegrationGuard.Violation.pullRequestMerge.reason)

        XCTAssertEqual(try f.progress.list(taskId: task.id).filter { $0.kind == .error }.count, 2)
    }

    func testAnAbsolutePathIsDeniedAndRecordedLikeTheBareSpelling() async throws {
        let pushed = await f.preToolUse("/usr/bin/git push -u origin HEAD", sessionId: "w1", identity: identity)
        XCTAssertEqual(pushed?.permissionDecision, "deny")
        XCTAssertEqual(pushed?.reason, IntegrationGuard.Violation.push.reason)

        let opened = await f.preToolUse("/opt/homebrew/bin/gh pr create --draft", sessionId: "w1", identity: identity)
        XCTAssertEqual(opened?.reason, IntegrationGuard.Violation.pullRequestCreate.reason)

        let entries = try f.progress.list(taskId: task.id).filter { $0.kind == .error }
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries.contains { $0.text.contains("/usr/bin/git push -u origin HEAD") }, "\(entries)")
    }

    func testUnrelatedBashIsAllowedAndLeavesNoDenialRow() async throws {
        let decision = await f.preToolUse("git commit -m \"Add hello.txt\"", sessionId: "w1", identity: identity)
        XCTAssertNil(decision)
        XCTAssertTrue(try f.progress.list(taskId: task.id).isEmpty)
    }

    func testDenialIsRecordedAsAHookEventAndDoesNotTouchSessionState() async throws {
        _ = await f.preToolUse("git push", sessionId: "w1", identity: identity)
        let events = try HookEventStore(f.db).recent(sessionId: "w1", limit: 10)
        XCTAssertEqual(events.map(\.event), ["PreToolUse"])
        XCTAssertEqual(try f.sessions.get("w1")?.state, .running)
        XCTAssertEqual(try f.tasks.get(task.id)?.blocked, false)
    }

    func testAnOrchestratorGrantIsNotStoppedByTheGuardAndLeavesNoDenialRow() async throws {
        let orch = f.orchestratorIdentity
        let pushed = await f.preToolUse("git push -u origin HEAD", sessionId: "orch-session", identity: orch)
        let opened = await f.preToolUse("gh pr create --draft", sessionId: "orch-session", identity: orch)
        XCTAssertNil(pushed)
        XCTAssertNil(opened)
        XCTAssertTrue(try f.progress.list(taskId: task.id).isEmpty)
    }

    func testMergingAPullRequestIsStillDeniedForAnOrchestratorWithoutBlamingWorkers() async throws {
        let decision = await f.preToolUse("gh pr merge 42", sessionId: "orch-session", identity: f.orchestratorIdentity)
        XCTAssertEqual(decision?.permissionDecision, "deny")
        let reason = try XCTUnwrap(decision?.reason)
        XCTAssertFalse(reason.contains("worker"), reason)
        XCTAssertEqual(reason, IntegrationGuard.Violation.pullRequestMerge.reason(for: .orchestrator))
    }

    func testTheGuardDoesNotDependOnASessionRow() async throws {
        let orphan = TokenIdentity(token: "w9", scope: .worker, projectId: f.project.id, sessionId: nil, taskId: task.id)
        let decision = await f.preToolUse("git push", sessionId: "unknown-session", identity: orphan)
        XCTAssertEqual(decision?.permissionDecision, "deny")
        XCTAssertEqual(try f.progress.latest(taskId: task.id)?.kind, .error)
    }
}
