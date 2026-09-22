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

    /// The blocked task is the notification: `ProjectAttentionStore` sees it and the banner comes
    /// from there, so the sink raises none of its own and the badge cannot disagree with the banner.
    func testBlockingNotificationBlocksTheTaskWithoutItsOwnBanner() async throws {
        let task = try f.task("t", column: .running)
        try f.session("w1", taskId: task.id)
        let event = HookEvent(
            name: "Notification", sessionId: "w1", notificationType: "permission_prompt",
            notificationMessage: "May I run rm?", rawJSON: "{}"
        )
        _ = await f.hooks.handle(event, identity: f.workerIdentity(sessionId: "w1", taskId: task.id))

        let events = await f.events.events
        XCTAssertEqual(events, [.reportQueued(projectId: f.project.id)])
        XCTAssertEqual(try f.tasks.get(task.id)?.blocked, true)

        let attention = try XCTUnwrap(ProjectAttentionStore(f.db).attention(projectId: f.project.id))
        XCTAssertEqual(attention.cause(.blockedWorker)?.count, 1)
    }

    /// A blocking notification on a session with no task cannot raise the attention signal, which
    /// counts blocked *tasks*, so this is the one path that still posts its own banner.
    func testBlockingNotificationWithNoTaskStillNotifies() async throws {
        try f.session("w1", taskId: nil)
        let event = HookEvent(
            name: "Notification", sessionId: "w1", notificationType: "permission_prompt",
            notificationMessage: "May I run rm?", rawJSON: "{}"
        )
        _ = await f.hooks.handle(event, identity: f.workerIdentity(sessionId: "w1", taskId: nil))

        let events = await f.events.events
        XCTAssertEqual(events, [
            .notify(projectId: f.project.id, title: "Agent needs input", body: "May I run rm?")
        ])
        XCTAssertEqual(try f.sessions.get("w1")?.state, .blocked)
    }

    /// SPEC §7 → §10: the `Notification` hook is the only thing that puts a worker in the
    /// orchestrator's Blocked section, so the whole path is asserted in one place.
    func testNotificationHookPutsTheTaskInTheBlockedSection() async throws {
        let task = try f.task("Add the sidebar", column: .running)
        try f.session("f9047594", taskId: task.id)
        try f.sessions.recordActivity("f9047594", at: .nowMillis, lastTool: "Bash")
        let event = HookEvent(
            name: "Notification", sessionId: "f9047594", notificationType: "permission_prompt",
            notificationMessage: "Claude needs your permission", rawJSON: "{}"
        )

        _ = await f.hooks.handle(event, identity: f.workerIdentity(sessionId: "f9047594", taskId: task.id))

        let blocked = try XCTUnwrap(f.tasks.get(task.id))
        XCTAssertTrue(blocked.blocked)
        XCTAssertEqual(blocked.blockedReason, "Claude needs your permission")
        XCTAssertEqual(try f.sessions.get("f9047594")?.state, .blocked)

        // The banner for this comes from the project's attention signal, not from the sink.
        let events = await f.events.events
        XCTAssertEqual(events, [.reportQueued(projectId: f.project.id)])

        let items = AttentionSelection.needingAttention(
            tasks: try f.tasks.list(projectId: f.project.id),
            sessions: try f.sessions.all(projectId: f.project.id),
            awake: .init(now: .now),
            stallThreshold: TimeInterval(f.project.settings.caps.stallSeconds)
        )
        XCTAssertEqual(items.map(\.id), [task.id])
        XCTAssertEqual(items[0].kind, .blocked)
        XCTAssertEqual(items[0].reason, "Claude needs your permission")
        XCTAssertEqual(items[0].session?.sessionId, "f9047594")
    }

    func testPostToolUseClearsTheTaskOutOfTheBlockedSection() async throws {
        let task = try f.task("Add the sidebar", column: .running)
        try f.session("f9047594", taskId: task.id)
        _ = try f.board.block(taskId: task.id, sessionId: "f9047594", reason: "Claude needs your permission")

        let event = HookEvent(name: "PostToolUse", sessionId: "f9047594", toolName: "Bash", rawJSON: "{}")
        _ = await f.hooks.handle(event, identity: f.workerIdentity(sessionId: "f9047594", taskId: task.id))

        let items = AttentionSelection.needingAttention(
            tasks: try f.tasks.list(projectId: f.project.id),
            sessions: try f.sessions.all(projectId: f.project.id),
            awake: .init(now: .now),
            stallThreshold: TimeInterval(f.project.settings.caps.stallSeconds)
        )
        XCTAssertTrue(items.isEmpty)
    }

    /// `workerCompleted` runs `claude stop` on the session waiting on this very call, so the answer
    /// has to be built before it is raised, not after. The handler hands the stop back on the result
    /// instead of awaiting it; `BoardServer` runs it once the body is on the wire.
    func testReportCompleteDefersTheStopUntilAfterItsAnswer() async throws {
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
        let beforeTheAnswerIsOut = await f.events.events
        XCTAssertEqual(
            beforeTheAnswerIsOut, [.reportQueued(projectId: f.project.id)],
            "the worker was stopped before it could be told its report landed"
        )
        XCTAssertEqual(try f.tasks.get(task.id)?.column, .review)
        XCTAssertEqual(try f.reports.unconsumedCount(projectId: f.project.id), 1)

        let stop = try XCTUnwrap(result.afterResponse)
        await stop()

        let afterTheAnswerIsOut = await f.events.events
        XCTAssertEqual(
            afterTheAnswerIsOut,
            [
                .reportQueued(projectId: f.project.id),
                .workerCompleted(projectId: f.project.id, sessionId: "w1"),
            ]
        )
    }

    /// The MCP client resends `report_complete` when the answer never arrives — before the stop was
    /// deferred, that was 64 of 183 completing sessions. The resend must find the first report and
    /// do nothing else — no second row, no second stop, and no undoing of whatever the orchestrator
    /// did with the first one.
    func testASecondReportCompleteInsertsNothingAndRerunsNothing() async throws {
        let task = try f.task("t", column: .running)
        try f.session("w1", taskId: task.id)
        let identity = f.workerIdentity(sessionId: "w1", taskId: task.id)
        let arguments: JSONValue = .object([
            "summary": .string("did it"),
            "files_changed": .array([.string("a.swift")]),
            "tests_run": .string("swift test"),
            "caveats": .string("none"),
        ])

        let first = try await f.scoped.call("report_complete", arguments: arguments, identity: identity)
        await first.afterResponse?()
        _ = try f.board.accept(taskId: task.id)
        let endedAt = try XCTUnwrap(f.sessions.get("w1")?.endedAt)

        let second = try await f.scoped.call("report_complete", arguments: arguments, identity: identity)
        XCTAssertNil(second.afterResponse, "the resend asked for the worker to be stopped a second time")

        let completes = try f.reports.unconsumed(projectId: f.project.id).filter { $0.kind == .complete }
        XCTAssertEqual(completes.count, 1)
        let reportId = try XCTUnwrap(completes[0].id)
        XCTAssertTrue(first.text.contains("Report \(reportId) recorded"), first.text)
        XCTAssertTrue(second.text.contains("Report \(reportId) was already recorded"), second.text)
        XCTAssertFalse(second.isError)
        XCTAssertEqual(try f.tasks.get(task.id)?.column, .done, "the resend dragged an accepted task back")
        XCTAssertEqual(try f.sessions.get("w1")?.endedAt, endedAt)

        let events = await f.events.events
        XCTAssertEqual(events.filter { $0 == .workerCompleted(projectId: f.project.id, sessionId: "w1") }.count, 1)
        XCTAssertEqual(events.filter { $0 == .reportQueued(projectId: f.project.id) }.count, 1)
    }

    func testReportBlockedQueuesAndRaisesTheAttentionSignal() async throws {
        let task = try f.task("t", column: .running)
        try f.session("w1", taskId: task.id)
        let identity = f.workerIdentity(sessionId: "w1", taskId: task.id)

        _ = try await f.scoped.call("report_blocked", arguments: .object(["reason": .string("need creds")]), identity: identity)

        let events = await f.events.events
        XCTAssertEqual(events, [.reportQueued(projectId: f.project.id)])

        let attention = try XCTUnwrap(ProjectAttentionStore(f.db).attention(projectId: f.project.id))
        XCTAssertEqual(attention.cause(.blockedWorker)?.detail, "t")
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
