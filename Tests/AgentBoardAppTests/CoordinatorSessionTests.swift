import AgentBoardCore
import AgentBoardRuntime
import Foundation
import XCTest
@testable import AgentBoard

/// SPEC §8.2: the Coordinator's session, end to end. Real supervisor, real board server over HTTP,
/// a real PTY running a fake `claude` that records its arguments and then waits like a session.
@MainActor
final class CoordinatorSessionTests: XCTestCase {
    private var fixture: SupervisorFixture!
    private var fakeClaudeDir: URL!

    override func setUp() async throws {
        fakeClaudeDir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("agentboard-fake-claude/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fakeClaudeDir, withIntermediateDirectories: true)
        let script = fakeClaudeDir.appendingPathComponent("claude")
        try """
        #!/bin/sh
        dir="$(dirname "$0")/launches"
        mkdir -p "$dir"
        n=$(ls "$dir" | wc -l | tr -d ' ')
        printf '%s\\0' "$@" > "$dir/.pending"
        mv "$dir/.pending" "$dir/$((n + 1))"
        exec /bin/cat
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        fixture = try SupervisorFixture.make(claude: ClaudeInvocation(executable: script.path))
        await fixture.supervisor.start()
        try XCTSkipIf(fixture.supervisor.serverPort == nil, "the board server could not bind a port")
    }

    override func tearDown() async throws {
        fixture.supervisor.stopOrchestratorConsoles()
        await fixture.cleanUp()
        try? FileManager.default.removeItem(at: fakeClaudeDir)
        fixture = nil
    }

    func testTheCoordinatorLaunchesInItsFolderWithReposReadOnlyAndKeepsItsSessions() async throws {
        let coordinator = CoordinatorStore(fixture.db)
        let console = fixture.supervisor.coordinatorSessionConsole()
        console.start()
        let first = try await launch(1)

        let claudeMd = fixture.coordinatorDir.appendingPathComponent("CLAUDE.md")
        XCTAssertEqual(try String(contentsOf: claudeMd, encoding: .utf8), CoordinatorHome.starterClaudeMd)
        try "My own rules.\n".write(to: claudeMd, atomically: true, encoding: .utf8)

        XCTAssertEqual(value(after: "--add-dir", in: first), fixture.fakeHome.path)
        XCTAssertTrue(first.contains("Edit(/\(fixture.project.repoPath)/**)"), first.description)
        let firstId = try XCTUnwrap(value(after: "--session-id", in: first))
        XCTAssertEqual(try coordinator.activeSessionId(), firstId)

        // `/clear` forks the session under a new id; only the hook's grant links the two.
        let token = try XCTUnwrap(fixture.grants.forSession(firstId).first).token
        let forkId = UUID().uuidString.lowercased()
        let transcript = ClaudeProjectPaths.transcriptURL(
            forCwd: fixture.coordinatorDir.path, sessionId: forkId,
            projectsRoot: fixture.supportDir.appendingPathComponent("claude-projects")
        )
        try writeTranscript(at: transcript, input: 1_200, output: 300)
        _ = try await hook([
            "hook_event_name": "SessionStart", "session_id": forkId, "source": "clear",
            "transcript_path": transcript.path,
        ], token: token)

        XCTAssertEqual(try fixture.grants.forSession(forkId).map(\.token), [token], "the hook did not bind the grant")
        XCTAssertEqual(try fixture.sessions.get(forkId)?.role, .coordinator)
        XCTAssertEqual(try coordinator.activeSessionId(), forkId)
        await fixture.supervisor.meterTick()
        let metered = try XCTUnwrap(fixture.sessions.get(forkId))
        XCTAssertEqual(metered.tokensIn, 1_200)
        XCTAssertEqual(metered.tokensOut, 300)
        XCTAssertGreaterThan(metered.estCostUSD, 0)

        let infra = try ProjectStore(fixture.db).register(
            name: "Infra", repoPath: fixture.supportDir.appendingPathComponent("infra").path, baseBranch: "main",
            worktreeRoot: fixture.supportDir.appendingPathComponent("worktrees-infra").path,
            memoryDir: fixture.supportDir.appendingPathComponent("memory-infra").path
        )
        XCTAssertFalse(first.contains("Edit(/\(infra.repoPath)/**)"))

        try fixture.supervisor.newCoordinatorSession()
        let second = try await launch(2)
        let secondId = try XCTUnwrap(value(after: "--session-id", in: second))
        XCTAssertFalse([firstId, forkId].contains(secondId), "New session resumed an old one")
        XCTAssertTrue(second.contains("Edit(/\(infra.repoPath)/**)"), "the new project's repo is writable")
        XCTAssertEqual(Set(try coordinator.history().map(\.sessionId)), [firstId, forkId])
        XCTAssertEqual(try String(contentsOf: claudeMd, encoding: .utf8), "My own rules.\n")

        try fixture.supervisor.resumeCoordinatorSession(sessionId: forkId)
        let resumed = try await launch(3)
        XCTAssertEqual(value(after: "--resume", in: resumed), forkId)

        console.stop()
        let relaunched = fixture.relaunchedSupervisor()
        await relaunched.start()
        try XCTSkipIf(relaunched.serverPort == nil, "the relaunched board server could not bind a port")
        relaunched.coordinatorSessionConsole().start()
        defer { relaunched.stopOrchestratorConsoles() }
        let afterRelaunch = try await launch(4)
        XCTAssertEqual(value(after: "--resume", in: afterRelaunch), forkId, "the next launch lost the session")
    }

    /// Rita's FYI on d8010a36: a switched-away session kept a live grant and could still call tools.
    func testSwitchingSessionsRefusesThePreviousSessionsToken() async throws {
        let coordinator = CoordinatorStore(fixture.db)
        fixture.supervisor.coordinatorSessionConsole().start()
        _ = try await launch(1)
        let firstToken = try XCTUnwrap(fixture.grants.forSession(XCTUnwrap(coordinator.activeSessionId())).first).token
        let before = try await mcpStatus(token: firstToken)
        XCTAssertEqual(before, 200)

        try fixture.supervisor.newCoordinatorSession()
        _ = try await launch(2)
        let secondId = try XCTUnwrap(coordinator.activeSessionId())
        let secondToken = try XCTUnwrap(fixture.grants.forSession(secondId).first { !$0.isRevoked }).token
        let afterNew = try await mcpStatus(token: firstToken)
        XCTAssertEqual(afterNew, 401, "New session left the previous session's token live")

        let firstId = try XCTUnwrap(coordinator.history().first).sessionId
        try fixture.supervisor.resumeCoordinatorSession(sessionId: firstId)
        _ = try await launch(3)
        let afterResume = try await mcpStatus(token: secondToken)
        XCTAssertEqual(afterResume, 401, "resuming left the switched-away session's token live")
    }

    func testTheSettingsSheetsModelIsTheOneTheNextLaunchUses() async throws {
        fixture.supervisor.coordinatorSessionConsole().start()
        let first = try await launch(1)
        XCTAssertNil(value(after: "--model", in: first), "the default is Claude Code's own")

        try CoordinatorSettingsSheet.save(model: "claude-sonnet-5", db: fixture.db)
        try fixture.supervisor.newCoordinatorSession()
        let second = try await launch(2)
        XCTAssertEqual(value(after: "--model", in: second), "claude-sonnet-5")
    }

    func testALaunchStopsCoordinatorRowsACrashLeftLive() async throws {
        let orphan = UUID().uuidString.lowercased()
        try fixture.sessions.insert(AgentSession(
            sessionId: orphan, projectId: "", role: .coordinator, cwd: fixture.coordinatorDir.path, state: .running
        ))
        let relaunched = fixture.relaunchedSupervisor()
        await relaunched.start()
        XCTAssertEqual(try fixture.sessions.get(orphan)?.state, .stopped)
    }

    /// The arguments of the fake `claude`'s `n`th launch.
    private func launch(_ n: Int) async throws -> [String] {
        let file = fakeClaudeDir.appendingPathComponent("launches/\(n)")
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !FileManager.default.fileExists(atPath: file.path), ContinuousClock.now < deadline {
            try await _Concurrency.Task.sleep(for: .milliseconds(20))
        }
        let data = try Data(contentsOf: file)
        return String(decoding: data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: false)
            .dropLast().map(String.init)
    }

    private func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    private func writeTranscript(at url: URL, input: Int, output: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line: [String: Any] = [
            "type": "assistant", "timestamp": "2026-09-25T10:00:01.000Z", "requestId": "req_A",
            "message": [
                "model": "claude-opus-5", "id": "msg_A",
                "usage": ["input_tokens": input, "output_tokens": output],
                "content": [["type": "text", "text": "hi"]],
            ] as [String: Any],
        ]
        try (String(decoding: try JSONSerialization.data(withJSONObject: line), as: UTF8.self) + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }

    private func mcpStatus(token: String) async throws -> Int {
        let port = try XCTUnwrap(fixture.supervisor.serverPort)
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/mcp")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "list_projects", "arguments": [:] as [String: Any]],
        ])
        let (_, response) = try await URLSession.shared.data(for: request)
        return try XCTUnwrap(response as? HTTPURLResponse).statusCode
    }

    private func hook(_ payload: [String: Any], token: String) async throws -> [String: Any] {
        let port = try XCTUnwrap(fixture.supervisor.serverPort)
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/hooks?token=\(token)")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, _) = try await URLSession.shared.data(for: request)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
