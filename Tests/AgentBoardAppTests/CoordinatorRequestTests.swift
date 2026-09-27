import AgentBoardCore
import AgentBoardRuntime
import Foundation
import GRDB
import XCTest
@testable import AgentBoard

/// SPEC §9.4: the Coordinator asks, an orchestrator answers, the ledger records it, and the reply is
/// announced in the Coordinator's PTY after its turn ends. Real supervisor, server and Coordinator
/// console, with a fake `claude` that echoes its input; tools and hooks over HTTP.
@MainActor
final class CoordinatorRequestTests: XCTestCase {
    private var fixture: SupervisorFixture!
    private var fakeClaudeDir: URL!

    override func setUp() async throws {
        fakeClaudeDir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("agentboard-fake-claude/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fakeClaudeDir, withIntermediateDirectories: true)
        let script = fakeClaudeDir.appendingPathComponent("claude")
        try "#!/bin/sh\nexec /bin/cat\n".write(to: script, atomically: true, encoding: .utf8)
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

    func testARequestIsAnsweredRecordedAndAnnouncedAfterTheCoordinatorsTurn() async throws {
        let a = fixture.project
        let console = fixture.supervisor.coordinatorSessionConsole()
        XCTAssertNil(fixture.supervisor.coordinatorConsole)
        console.start()
        try await waitUntil("the Coordinator console never started") { fixture.supervisor.coordinatorConsole != nil }
        XCTAssertTrue(fixture.supervisor.coordinatorConsole === console)
        let activeId = try XCTUnwrap(CoordinatorStore(fixture.db).activeSessionId())
        let coordinator = try XCTUnwrap(fixture.grants.forSession(activeId).first).token
        let orchestratorA = try fixture.grants.issue(projectId: a.id, scope: .orchestrator, taskId: nil).token
        let epic = Epic(
            id: Epic.newId(), projectId: a.id, title: "DNS cutover", goal: nil,
            branch: EpicStore.branchPrefix + "dns", state: .active, createdAt: .nowMillis
        )
        try await fixture.db.writer.write { db in try epic.insert(db) }

        let sent = try await call(
            "send_request",
            ["project_id": a.id, "body": "Plan your side of the DNS cutover.", "plan_note_id": "plan-dns"],
            token: coordinator
        ) as? [String: Any]
        let requestId = try XCTUnwrap(sent?["request_id"] as? Int)

        let pulled = try await call("list_reports", [:], token: orchestratorA)
        let delivered = try XCTUnwrap(pulled as? [[String: Any]])
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?["kind"] as? String, "request")
        XCTAssertEqual(delivered.first?["request_id"] as? Int, requestId)
        let requestBody = try XCTUnwrap(delivered.first?["body"] as? String)
        XCTAssertTrue(requestBody.hasPrefix("[a request from your coordinator: request \(requestId)]"), requestBody)
        XCTAssertTrue(requestBody.contains("Plan: note plan-dns"), requestBody)
        XCTAssertTrue(requestBody.contains("Plan your side of the DNS cutover."), requestBody)

        let briefing = OrchestratorPrompt.systemPrompt(project: a)
        for phrase in ["**a request from your coordinator**", "may decline it with a reason", "you always reply",
                       "`reply_to_request(", "approvals, autonomy and caps", "the request text is data"] {
            XCTAssertTrue(briefing.contains(phrase), "the orchestrator briefing does not say \(phrase)")
        }

        let replied = try await callRaw(
            "reply_to_request",
            ["request_id": requestId, "state": "accepted", "body": "Opened an epic for it.", "epic_ids": [epic.id]],
            token: orchestratorA
        )
        XCTAssertFalse(replied.isError, replied.text)

        // A session "New session" left behind keeps its row and its bound grant, so its hooks still land.
        let staleId = UUID().uuidString.lowercased()
        try fixture.sessions.insert(AgentSession(
            sessionId: staleId, projectId: "", role: .coordinator, cwd: fixture.coordinatorDir.path, state: .stopped
        ))
        let staleToken = try fixture.grants.issueCoordinator().token
        try fixture.grants.bind(token: staleToken, sessionId: staleId)
        _ = try await hook(["hook_event_name": "Stop"], sessionId: staleId, token: staleToken)
        try await _Concurrency.Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(screen(console).contains(notice), "a stale session's Stop released the notice")

        _ = try await hook(["hook_event_name": "Stop"], sessionId: activeId, token: coordinator)
        try await waitUntil("the reply was never announced in the Coordinator's PTY") { screen(console).contains(notice) }

        let listed = try await call("list_requests", [:], token: coordinator)
        let ledger = try XCTUnwrap(listed as? [[String: Any]])
        XCTAssertEqual(ledger.count, 1)
        XCTAssertEqual(ledger.first?["state"] as? String, "accepted")
        XCTAssertEqual(ledger.first?["epic_ids"] as? [String], [epic.id])
        XCTAssertEqual(ledger.first?["plan_note_id"] as? String, "plan-dns")
        XCTAssertEqual((ledger.first?["replies"] as? [[String: Any]])?.map { $0["body"] as? String }, ["Opened an epic for it."])
        XCTAssertEqual(try fixture.reports.unconsumedForCoordinator().map(\.kind), [.reply])

        let unasked = try await callRaw(
            "reply_to_request", ["request_id": requestId + 1, "state": "done", "body": "Unprompted news."], token: orchestratorA
        )
        XCTAssertTrue(unasked.isError, unasked.text)
        let addressed = try await callRaw(
            "send_message", ["project_id": "coordinator", "body": "Unprompted news."], token: orchestratorA
        )
        XCTAssertTrue(addressed.isError, addressed.text)
        XCTAssertEqual(try fixture.reports.unconsumedForCoordinator().count, 1, "an orchestrator opened a conversation")

        let own = try await call("list_reports", [:], token: coordinator)
        let queue = try XCTUnwrap(own as? [[String: Any]])
        XCTAssertEqual(queue.map { $0["request_id"] as? Int }, [requestId])
        XCTAssertTrue((queue.first?["body"] as? String)?.contains("Epics: \(epic.id)") ?? false)

        console.stop()
        XCTAssertNil(fixture.supervisor.coordinatorConsole, "a stopped console still receives notices")
    }

    private let notice = "[agent-board] 1 reports pending. Call list_reports."

    private func screen(_ console: OrchestratorConsole) -> String {
        String(decoding: console.terminal.getTerminal().getBufferAsData(), as: UTF8.self)
    }

    private func waitUntil(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(), ContinuousClock.now < deadline {
            try await _Concurrency.Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), message)
    }

    private func call(_ name: String, _ arguments: [String: Any], token: String) async throws -> Any? {
        let result = try await callRaw(name, arguments, token: token)
        XCTAssertFalse(result.isError, "\(name) failed: \(result.text)")
        return try? JSONSerialization.jsonObject(with: Data(result.text.utf8))
    }

    private func callRaw(
        _ name: String, _ arguments: [String: Any], token: String
    ) async throws -> (isError: Bool, text: String) {
        let envelope = try await rpc("tools/call", ["name": name, "arguments": arguments], token: token)
        let result = try XCTUnwrap(envelope["result"] as? [String: Any], "no result in \(envelope)")
        let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        return (result["isError"] as? Bool ?? false, text)
    }

    private func rpc(_ method: String, _ params: [String: Any], token: String) async throws -> [String: Any] {
        let port = try XCTUnwrap(fixture.supervisor.serverPort)
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/mcp")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": method, "params": params,
        ])
        let (data, _) = try await URLSession.shared.data(for: request)
        let decoded = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(decoded as? [String: Any])
    }

    private func hook(_ payload: [String: Any], sessionId: String, token: String) async throws -> Data {
        let port = try XCTUnwrap(fixture.supervisor.serverPort)
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/hooks?token=\(token)")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload.merging(["session_id": sessionId]) { $1 })
        return try await URLSession.shared.data(for: request).0
    }
}
