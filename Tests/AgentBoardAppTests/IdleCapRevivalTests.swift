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
    private var server: BoardServer!
    private var port = 0
    private var revivedHost: Process?

    override func setUp() async throws {
        fixture = try SupervisorFixture.make()
        let sink = LateBoundSink()
        sink.target = fixture.supervisor
        server = BoardServer(
            tokens: StoreTokenResolver(db: fixture.db),
            hooks: StoreHookSink(db: fixture.db, events: sink),
            tools: Wiring.tools(db: fixture.db, sink: sink, scopedCommits: nil)
        )
        port = try await server.start(preferredPort: nil)
    }

    override func tearDown() async throws {
        if revivedHost?.isRunning == true { revivedHost?.terminate() }
        await server.stop()
        await fixture.cleanUp()
        fixture = nil
    }

    func testAnIdleCappedSessionWhoseSessionEndWonTheRaceCanCallNoToolAndIsStoppedAgainWhenResumed() async throws {
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
        let port = port
        await fixture.runtime.whenStopped(shortId: shortId) {
            _ = try? await Self.hook(
                ["hook_event_name": "SessionEnd", "session_id": sessionId, "reason": "other"], port: port, token: token
            )
        }

        await fixture.supervisor.meter(
            session,
            limits: CapLimits(maxTokens: nil, maxWallClockSeconds: nil, maxIdleSeconds: 300),
            stallSeconds: 100_000,
            awake: AwakeElapsed(nowMillis: .nowMillis)
        )
        XCTAssertEqual(try fixture.sessions.get(sessionId)?.state, .stopped, "SessionEnd did not land before terminate")
        let toolCall = try await mcpStatus("get_my_task", token: token)
        XCTAssertEqual(toolCall, 401)

        let host = Process()
        host.executableURL = URL(fileURLWithPath: "/bin/sleep")
        host.arguments = ["600"]
        try host.run()
        revivedHost = host
        await fixture.runtime.host(host.processIdentifier, shortId: shortId)

        let started = try await Self.hook(
            ["hook_event_name": "SessionStart", "session_id": sessionId, "source": "resume"], port: port, token: token
        )
        XCTAssertEqual(started, 200)

        let deadline = ContinuousClock.now + .seconds(10)
        while host.isRunning, ContinuousClock.now < deadline {
            try await _Concurrency.Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(host.isRunning, "the resumed session's process outlived the idle cap that ended it")
        XCTAssertEqual(try fixture.sessions.get(sessionId)?.state, .stopped)
    }

    private func mcpStatus(_ tool: String, token: String) async throws -> Int {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/mcp")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": tool, "arguments": [String: Any]()],
        ])
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    private nonisolated static func hook(_ payload: [String: String], port: Int, token: String) async throws -> Int {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/hooks?token=\(token)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}
