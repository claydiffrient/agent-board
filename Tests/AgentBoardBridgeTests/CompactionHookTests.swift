import AgentBoardCore
import AgentBoardServer
import XCTest
@testable import AgentBoardBridge

final class CompactionHookTests: XCTestCase {
    private var fixture: BridgeFixture!

    override func setUpWithError() throws {
        fixture = try BridgeFixture.make()
    }

    private func event(_ name: String, sessionId: String, trigger: String? = nil, agentType: String? = nil) -> HookEvent {
        var payload: [String: Any] = ["hook_event_name": name, "session_id": sessionId]
        if let trigger { payload["trigger"] = trigger }
        if let agentType { payload["agent_type"] = agentType }
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return HookEvent(
            name: name, sessionId: sessionId, compactTrigger: trigger, agentType: agentType,
            rawJSON: String(decoding: data, as: UTF8.self)
        )
    }

    private func recorded(_ sessionId: String) throws -> [String] {
        try fixture.hookEvents.recent(sessionId: sessionId).map(\.event).reversed()
    }

    private func payloads(_ sessionId: String) throws -> [String] {
        try fixture.hookEvents.recent(sessionId: sessionId).map(\.payload)
    }

    private func briefedTask() throws -> (BoardTask, AgentSession, TokenIdentity) {
        let task = try fixture.tasks.create(
            projectId: fixture.project.id,
            title: "Wire the compaction hook",
            body: "PreCompact is not configured today, so a compacted worker loses its assignment.",
            acceptance: "swift build clean and a test drives the payload through StoreHookSink.",
            priority: nil, column: .running, origin: .human, epicId: nil
        )
        let session = try fixture.session("s-compact", taskId: task.id)
        return (task, session, fixture.workerIdentity(sessionId: session.sessionId, taskId: task.id))
    }

    func testSubagentStopIsRecordedAgainstTheSession() async throws {
        let (task, session, identity) = try briefedTask()
        XCTAssertNil(try fixture.sessions.get(session.sessionId)?.lastActivity)

        let decision = await fixture.hooks.handle(
            event("SubagentStop", sessionId: session.sessionId, agentType: "Explore"), identity: identity
        )

        XCTAssertNil(decision)
        XCTAssertEqual(try recorded(session.sessionId), ["SubagentStop"])
        XCTAssertTrue(try payloads(session.sessionId).joined().contains("Explore"))
        XCTAssertNotNil(try fixture.sessions.get(session.sessionId)?.lastActivity)
        XCTAssertEqual(try fixture.tasks.get(task.id)?.id, task.id)
    }

    /// The hook reference gives `PreCompact` one decision field, a top-level `decision: "block"`
    /// that blocks the compaction, and does not list it among the events accepting
    /// `hookSpecificOutput.additionalContext`. So the response stays empty and the brief rides the
    /// next `PostToolUse`.
    func testPreCompactIsRecordedAndReturnsNoDecision() async throws {
        let (_, session, identity) = try briefedTask()

        let decision = await fixture.hooks.handle(
            event("PreCompact", sessionId: session.sessionId, trigger: "auto"), identity: identity
        )

        XCTAssertNil(decision)
        XCTAssertEqual(try recorded(session.sessionId), ["PreCompact"])
    }

    func testPreCompactPutsTheCompactionOnTheTaskCard() async throws {
        let (task, session, identity) = try briefedTask()

        _ = await fixture.hooks.handle(
            event("PreCompact", sessionId: session.sessionId, trigger: "manual"), identity: identity
        )

        let status = try fixture.progress.list(taskId: task.id).first { $0.kind == .status }
        let row = try XCTUnwrap(status)
        XCTAssertEqual(row.text, "Context compacted manually; re-sending the task brief.")
        XCTAssertEqual(row.sessionId, session.sessionId)
    }

    func testTheNextPostToolUseCarriesTheTaskBackIntoTheSession() async throws {
        let (task, session, identity) = try briefedTask()
        let note = try fixture.note("Offscreen rendering", sections: [
            (heading: "What works", body: "CGWindowListCreateImage against an offscreen NSWindow."),
        ])
        try fixture.notes.attach(noteId: note.id, taskId: task.id)

        _ = await fixture.hooks.handle(
            event("PreCompact", sessionId: session.sessionId, trigger: "auto"), identity: identity
        )
        let delivered = await fixture.hooks.handle(
            HookEvent(name: "PostToolUse", sessionId: session.sessionId, toolName: "Bash", rawJSON: "{}"),
            identity: identity
        )
        let brief = try XCTUnwrap(delivered?.additionalContext)
        let decision = try XCTUnwrap(delivered)
        XCTAssertTrue(brief.contains("Wire the compaction hook"), brief)
        XCTAssertTrue(brief.contains("PreCompact is not configured today"), brief)
        XCTAssertTrue(brief.contains("swift build clean and a test drives the payload"), brief)
        XCTAssertTrue(brief.contains("CGWindowListCreateImage against an offscreen NSWindow."), brief)
        XCTAssertTrue(brief.contains(OpeningPrompt.noteOpenMarker), brief)

        // Context only: no verdict field, so the CLI cannot read this as a block on the tool call.
        let body = decision.responseBody(hookEventName: "PostToolUse")
        XCTAssertNil(body["decision"])
        let specific = try XCTUnwrap(body["hookSpecificOutput"] as? [String: Any])
        XCTAssertNil(specific["permissionDecision"])
        XCTAssertEqual(specific["additionalContext"] as? String, brief)
    }

    func testTheBriefIsSentOnceAndOnlyAfterACompaction() async throws {
        let (_, session, identity) = try briefedTask()
        let postToolUse = HookEvent(name: "PostToolUse", sessionId: session.sessionId, toolName: "Bash", rawJSON: "{}")

        var delivered = await fixture.hooks.handle(postToolUse, identity: identity)
        XCTAssertNil(delivered, "a session that was never compacted got a re-brief")

        _ = await fixture.hooks.handle(event("PreCompact", sessionId: session.sessionId, trigger: "auto"), identity: identity)
        delivered = await fixture.hooks.handle(postToolUse, identity: identity)
        XCTAssertNotNil(delivered?.additionalContext)

        delivered = await fixture.hooks.handle(postToolUse, identity: identity)
        XCTAssertNil(delivered, "the brief was sent twice for one compaction")
    }

    func testAnOrchestratorIsNotReBriefed() async throws {
        let session = try fixture.session("s-orch", role: .orchestrator, taskId: nil)
        let identity = fixture.orchestratorIdentity

        _ = await fixture.hooks.handle(event("PreCompact", sessionId: session.sessionId, trigger: "auto"), identity: identity)
        let decision = await fixture.hooks.handle(
            HookEvent(name: "PostToolUse", sessionId: session.sessionId, toolName: "Bash", rawJSON: "{}"),
            identity: identity
        )

        XCTAssertNil(decision)
        XCTAssertEqual(try recorded(session.sessionId), ["PreCompact", "PostToolUse"])
    }
}
