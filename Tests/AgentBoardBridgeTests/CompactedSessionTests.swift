import AgentBoardCore
import AgentBoardServer
import XCTest
@testable import AgentBoardBridge

/// `/clear` forks the session id; `/compact` does not. Measured 2026-09-12 and again 2026-09-15 by
/// driving a real `claude` PTY with hooks pointed at a scratch `hook_event` table: a compaction
/// emits `PreCompact` then `SessionStart {"source":"compact"}` under the *same* `session_id`, with
/// the same `transcript_path` and no `SessionEnd` (SPEC §2). So there is no fork to adopt here —
/// what these pin is that the existing row, grant and pin all survive untouched, and that the
/// console is told so it can re-orient the session.
final class CompactedSessionTests: XCTestCase {
    private func sessionStart(_ sessionId: String, source: String, transcript: String) -> HookEvent {
        HookEvent(
            name: "SessionStart",
            sessionId: sessionId,
            transcriptPath: transcript,
            sessionSource: source,
            rawJSON: #"{"hook_event_name":"SessionStart","source":"\#(source)"}"#
        )
    }

    /// The raw JSON matters here: the trigger is read back out of the stored `hook_event` row,
    /// because the `SessionStart` that follows a `PreCompact` does not carry it.
    private func preCompact(_ sessionId: String, trigger: String) -> HookEvent {
        HookEvent(
            name: "PreCompact",
            sessionId: sessionId,
            compactTrigger: trigger,
            rawJSON: #"{"hook_event_name":"PreCompact","trigger":"\#(trigger)","custom_instructions":null}"#
        )
    }

    private func orchestratorFixture() throws -> (BridgeFixture, AgentSession, TokenIdentity) {
        let fixture = try BridgeFixture.make()
        let session = AgentSession(
            sessionId: "orch-session", projectId: fixture.project.id, taskId: nil,
            role: .orchestrator, cwd: fixture.project.repoPath, state: .running
        )
        try fixture.sessions.insert(session)
        try fixture.projects.setOrchestratorSession(fixture.project.id, sessionId: session.sessionId)
        let grant = try TokenGrantStore(fixture.db).issue(
            projectId: fixture.project.id, scope: .orchestrator, taskId: nil
        )
        try TokenGrantStore(fixture.db).bind(token: grant.token, sessionId: session.sessionId)
        let identity = TokenIdentity(
            token: grant.token, scope: .orchestrator,
            projectId: fixture.project.id, sessionId: session.sessionId
        )
        return (fixture, session, identity)
    }

    func testACompactionKeepsTheSessionRowTheGrantAndThePin() async throws {
        let (fixture, session, identity) = try orchestratorFixture()
        let before = try XCTUnwrap(fixture.sessions.get(session.sessionId))
        let boundBefore = try TokenGrantStore(fixture.db).forSession(session.sessionId)

        _ = await fixture.hooks.handle(preCompact(session.sessionId, trigger: "manual"), identity: identity)
        _ = await fixture.hooks.handle(
            sessionStart(session.sessionId, source: "compact", transcript: "/tmp/orch.jsonl"),
            identity: identity
        )

        let sessions = try fixture.sessions.all(projectId: fixture.project.id)
        XCTAssertEqual(sessions.map(\.sessionId), [session.sessionId], "a compaction created a second session row")

        let after = try XCTUnwrap(fixture.sessions.get(session.sessionId))
        XCTAssertEqual(after.projectId, before.projectId)
        XCTAssertEqual(after.role, .orchestrator)
        XCTAssertEqual(after.cwd, before.cwd)
        XCTAssertEqual(after.transcriptPath, "/tmp/orch.jsonl")

        XCTAssertEqual(
            try TokenGrantStore(fixture.db).forSession(session.sessionId).map(\.token),
            boundBefore.map(\.token),
            "the grant was revoked or reissued across a compaction"
        )
        XCTAssertEqual(
            try fixture.projects.get(fixture.project.id)?.orchSessionId,
            session.sessionId,
            "project.orch_session_id moved, so the next launch would resume the wrong session"
        )
    }

    func testAManualCompactionTellsTheConsoleItWasManual() async throws {
        let (fixture, session, identity) = try orchestratorFixture()

        _ = await fixture.hooks.handle(preCompact(session.sessionId, trigger: "manual"), identity: identity)
        _ = await fixture.hooks.handle(
            sessionStart(session.sessionId, source: "compact", transcript: "/tmp/orch.jsonl"),
            identity: identity
        )

        let events = await fixture.events.events
        XCTAssertTrue(events.contains(.orchestratorCompacted(
            projectId: fixture.project.id, sessionId: session.sessionId, manual: true
        )), "got \(events)")
    }

    /// Claude Code's own auto-compaction resumes the turn it interrupted, so the app must recognise
    /// it and stay out of the PTY.
    func testAnAutoCompactionIsReportedAsAutomatic() async throws {
        let (fixture, session, identity) = try orchestratorFixture()

        _ = await fixture.hooks.handle(preCompact(session.sessionId, trigger: "auto"), identity: identity)
        _ = await fixture.hooks.handle(
            sessionStart(session.sessionId, source: "compact", transcript: "/tmp/orch.jsonl"),
            identity: identity
        )

        let events = await fixture.events.events
        XCTAssertTrue(events.contains(.orchestratorCompacted(
            projectId: fixture.project.id, sessionId: session.sessionId, manual: false
        )), "got \(events)")
    }

    func testAnOrdinaryStartupIsNotReportedAsACompaction() async throws {
        let (fixture, session, identity) = try orchestratorFixture()

        _ = await fixture.hooks.handle(
            sessionStart(session.sessionId, source: "startup", transcript: "/tmp/orch.jsonl"),
            identity: identity
        )

        let events = await fixture.events.events
        XCTAssertFalse(events.contains { if case .orchestratorCompacted = $0 { return true } else { return false } })
    }

    func testAWorkerCompactionIsNotReportedToAnOrchestratorConsole() async throws {
        let fixture = try BridgeFixture.make()
        let task = try fixture.task("build it", column: .running)
        try fixture.session("worker-session", role: .worker, taskId: task.id)
        let identity = TokenIdentity(
            token: "w", scope: .worker, projectId: fixture.project.id,
            sessionId: "worker-session", taskId: task.id
        )

        _ = await fixture.hooks.handle(preCompact("worker-session", trigger: "auto"), identity: identity)
        _ = await fixture.hooks.handle(
            sessionStart("worker-session", source: "compact", transcript: "/tmp/w.jsonl"),
            identity: identity
        )

        let events = await fixture.events.events
        XCTAssertFalse(events.contains { if case .orchestratorCompacted = $0 { return true } else { return false } })
    }
}
