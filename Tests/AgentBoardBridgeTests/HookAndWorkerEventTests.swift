import AgentBoardBridge
import AgentBoardCore
import AgentBoardServer
import Foundation
import XCTest

final class HookAndWorkerEventTests: XCTestCase {
    private var f: BridgeFixture!

    override func setUpWithError() throws {
        f = try BridgeFixture.make()
    }

    func testOrchestratorStopRoutesToTurnEndedAndLeavesStateAlone() async throws {
        try f.session("orch-1", role: .orchestrator, state: .running)
        let identity = TokenIdentity(token: "orch", scope: .orchestrator, projectId: f.project.id, sessionId: "orch-1")

        await f.hook("Stop", sessionId: "orch-1", identity: identity, lastAssistantMessage: "done thinking")

        let events = await f.events.events
        XCTAssertEqual(events, [.orchestratorTurnEnded(projectId: f.project.id, sessionId: "orch-1")])
        XCTAssertEqual(try f.sessions.get("orch-1")?.state, .running)
    }

    func testWorkerStopGoesIdleWithoutTurnEndedEvent() async throws {
        let task = try f.task("t", column: .running)
        try f.session("w1", taskId: task.id)

        await f.hook("Stop", sessionId: "w1", identity: f.workerIdentity(sessionId: "w1", taskId: task.id), lastAssistantMessage: "paused")

        let session = try XCTUnwrap(f.sessions.get("w1"))
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(session.stopReason, "paused")
        let events = await f.events.events
        XCTAssertEqual(events, [])
    }

    func testBlockingNotificationPostsThroughEventSink() async throws {
        let task = try f.task("t", column: .running)
        try f.session("w1", taskId: task.id)
        let event = HookEvent(
            name: "Notification", sessionId: "w1", notificationType: "permission_prompt",
            notificationMessage: "May I run rm?", rawJSON: "{}"
        )
        _ = await f.hooks.handle(event, identity: f.workerIdentity(sessionId: "w1", taskId: task.id))

        let events = await f.events.events
        XCTAssertEqual(events, [
            .notify(title: "Agent needs input", body: "May I run rm?"),
            .reportQueued(projectId: f.project.id),
        ])
        XCTAssertEqual(try f.tasks.get(task.id)?.blocked, true)
    }

    func testReportCompleteTriggersReportQueued() async throws {
        let task = try f.task("t", column: .running)
        try f.session("w1", taskId: task.id)
        let identity = f.workerIdentity(sessionId: "w1", taskId: task.id)
        let arguments: JSONValue = .object([
            "summary": .string("did it"),
            "files_changed": .array([.string("a.swift")]),
            "tests_run": .string("swift test"),
            "caveats": .string("none"),
        ])

        let result = try await f.scoped.call("report_complete", arguments: arguments, identity: identity)

        XCTAssertFalse(result.isError)
        let events = await f.events.events
        XCTAssertEqual(events, [.reportQueued(projectId: f.project.id)])
        XCTAssertEqual(try f.tasks.get(task.id)?.column, .review)
        XCTAssertEqual(try f.reports.unconsumedCount(projectId: f.project.id), 1)
    }

    func testReportBlockedNotifiesAndQueues() async throws {
        let task = try f.task("t", column: .running)
        try f.session("w1", taskId: task.id)
        let identity = f.workerIdentity(sessionId: "w1", taskId: task.id)

        _ = try await f.scoped.call("report_blocked", arguments: .object(["reason": .string("need creds")]), identity: identity)

        let events = await f.events.events
        XCTAssertEqual(events, [
            .notify(title: "Worker blocked: t", body: "need creds"),
            .reportQueued(projectId: f.project.id),
        ])
    }

    func testProposeTaskQueuesReport() async throws {
        let task = try f.task("t", column: .running)
        try f.session("w1", taskId: task.id)
        let identity = f.workerIdentity(sessionId: "w1", taskId: task.id)

        _ = try await f.scoped.call("propose_task", arguments: .object(["title": .string("follow-up")]), identity: identity)

        let events = await f.events.events
        XCTAssertEqual(events, [.reportQueued(projectId: f.project.id)])
        XCTAssertEqual(try f.tasks.list(projectId: f.project.id, column: .proposed).count, 1)
    }
}
