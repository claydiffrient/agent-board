import AgentBoardBridge
import AgentBoardCore
import AgentBoardRuntime
import AgentBoardServer
import Foundation
import XCTest
@testable import AgentBoard

/// SPEC §8.5: Claude Code resumes a stopped `--bg` session by itself to deliver a background
/// command's notification, and the reap that kills that command is what produces one. Integrator
/// d44b3f51 was idle-capped at 10:43:15 on 2026-10-07, resumed at 10:43:43, and worked on for half
/// an hour under a `failed` row.
@MainActor
final class IdleCapRevivalTests: XCTestCase {
    private var fixture: SupervisorFixture!
    private var revivedHost: Process?

    override func setUp() async throws {
        fixture = try SupervisorFixture.make()
    }

    override func tearDown() async throws {
        if revivedHost?.isRunning == true { revivedHost?.terminate() }
        await fixture.cleanUp()
        fixture = nil
    }

    func testAnIdleCappedSessionThatClaudeCodeResumesIsStoppedAgain() async throws {
        let (_, sessionId, token) = try fixture.workerAtWork()
        let silentSince = Int64.nowMillis - 600_000
        try await fixture.db.writer.write { db in
            try db.execute(
                sql: "UPDATE agent_session SET started_at = ?, last_activity = ? WHERE session_id = ?",
                arguments: [silentSince, silentSince, sessionId]
            )
        }
        let session = try XCTUnwrap(fixture.sessions.get(sessionId))
        let shortId = try XCTUnwrap(session.shortId)

        await fixture.supervisor.meter(
            session,
            limits: CapLimits(maxTokens: nil, maxWallClockSeconds: nil, maxIdleSeconds: 300),
            stallSeconds: 100_000,
            awake: AwakeElapsed(nowMillis: .nowMillis)
        )
        XCTAssertEqual(try fixture.sessions.get(sessionId)?.state, .failed)

        let host = Process()
        host.executableURL = URL(fileURLWithPath: "/bin/sleep")
        host.arguments = ["600"]
        try host.run()
        revivedHost = host
        await fixture.runtime.host(host.processIdentifier, shortId: shortId)

        let hooks = StoreHookSink(db: fixture.db, events: fixture.supervisor)
        _ = await hooks.handle(
            HookEvent(name: "SessionStart", sessionId: sessionId, rawJSON: #"{"source":"resume"}"#),
            identity: try await fixture.identity(token: token)
        )

        let deadline = ContinuousClock.now + .seconds(10)
        while host.isRunning, ContinuousClock.now < deadline {
            try await _Concurrency.Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(host.isRunning, "the resumed session's process outlived the idle cap that ended it")
        XCTAssertEqual(try fixture.sessions.get(sessionId)?.state, .failed)
    }
}
