import AgentBoardServer
import Foundation
import XCTest

final class BoardServerTests: XCTestCase {
    static let workerToken = "worker-token-1"
    static let orchestratorToken = "orch-token-1"
    static let worker = TokenIdentity(token: workerToken, scope: .worker, projectId: "p1", sessionId: "s1", taskId: "t1")
    static let orchestrator = TokenIdentity(token: orchestratorToken, scope: .orchestrator, projectId: "p1", sessionId: "s0")

    private var server: BoardServer!
    private var hooks: RecordingHookSink!
    private var tools: FakeToolHandler!
    private var port = 0

    override func setUp() async throws {
        hooks = RecordingHookSink()
        tools = FakeToolHandler()
        let resolver = InMemoryTokenResolver([Self.worker])
        await resolver.add(Self.orchestrator)
        server = BoardServer(tokens: resolver, hooks: hooks, tools: tools)
        port = try await server.start()
    }

    override func tearDown() async throws {
        await server.stop()
        let stopped = await server.port
        XCTAssertNil(stopped)
    }

    // MARK: Lifecycle

    func testStartBindsEphemeralPortAndExposesIt() async throws {
        XCTAssertGreaterThan(port, 0)
        let reported = await server.port
        XCTAssertEqual(reported, port)
    }

    // MARK: Auth

    func testMCPWithoutTokenIsUnauthorized() async throws {
        let (status, json) = try await post("/mcp", headers: [:], body: rpc("ping", id: 1))
        XCTAssertEqual(status, 401)
        XCTAssertEqual(json as? [String: String], ["error": "unauthorized"])
    }

    func testMCPWithWrongTokenIsUnauthorized() async throws {
        let (status, json) = try await mcpRaw(rpc("ping", id: 1), token: "nope")
        XCTAssertEqual(status, 401)
        XCTAssertEqual(json as? [String: String], ["error": "unauthorized"])
    }

    func testMCPWithNonBearerSchemeIsUnauthorized() async throws {
        let (status, _) = try await post("/mcp", headers: ["Authorization": "Basic \(Self.workerToken)"], body: rpc("ping", id: 1))
        XCTAssertEqual(status, 401)
    }

    func testHooksWithWrongTokenIsUnauthorizedAndNotDelivered() async throws {
        let (status, json) = try await post("/hooks?token=bogus", headers: [:], body: ["hook_event_name": "Stop", "session_id": "s1"])
        XCTAssertEqual(status, 401)
        XCTAssertEqual(json as? [String: String], ["error": "unauthorized"])
        let events = await hooks.events
        XCTAssertTrue(events.isEmpty)
    }

    func testHooksWithoutTokenIsUnauthorized() async throws {
        let (status, _) = try await post("/hooks", headers: [:], body: ["hook_event_name": "Stop", "session_id": "s1"])
        XCTAssertEqual(status, 401)
    }

    // MARK: Hooks

    func testHooksParsesEventIncludingNestedNotificationMessage() async throws {
        let body: [String: Any] = [
            "hook_event_name": "Notification",
            "session_id": "abc-123",
            "transcript_path": "/tmp/transcript.jsonl",
            "cwd": "/repo/worktree",
            "tool_name": "Bash",
            "notification_type": "permission_prompt",
            "notification": ["message": "Claude needs permission to run git push"],
            "last_assistant_message": "I will push now.",
        ]
        let (status, json) = try await post("/hooks?token=\(Self.workerToken)", headers: [:], body: body)
        XCTAssertEqual(status, 200)
        XCTAssertEqual((json as? [String: Any])?.count, 0)

        let events = await hooks.events
        XCTAssertEqual(events.count, 1)
        let (event, identity) = events[0]
        XCTAssertEqual(identity, Self.worker)
        XCTAssertEqual(event.name, "Notification")
        XCTAssertEqual(event.sessionId, "abc-123")
        XCTAssertEqual(event.transcriptPath, "/tmp/transcript.jsonl")
        XCTAssertEqual(event.cwd, "/repo/worktree")
        XCTAssertEqual(event.toolName, "Bash")
        XCTAssertEqual(event.notificationType, "permission_prompt")
        XCTAssertEqual(event.notificationMessage, "Claude needs permission to run git push")
        XCTAssertEqual(event.lastAssistantMessage, "I will push now.")
        let raw = try JSONSerialization.jsonObject(with: Data(event.rawJSON.utf8)) as? [String: Any]
        XCTAssertEqual(raw?["session_id"] as? String, "abc-123")
        XCTAssertEqual((raw?["notification"] as? [String: Any])?["message"] as? String, "Claude needs permission to run git push")
    }

    func testHooksFallsBackToTopLevelMessage() async throws {
        let body: [String: Any] = [
            "hook_event_name": "Notification",
            "session_id": "abc-123",
            "message": "Agent is waiting for input",
        ]
        let (status, _) = try await post("/hooks?token=\(Self.orchestratorToken)", headers: [:], body: body)
        XCTAssertEqual(status, 200)
        let events = await hooks.events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].0.notificationMessage, "Agent is waiting for input")
        XCTAssertNil(events[0].0.toolName)
        XCTAssertEqual(events[0].1.scope, .orchestrator)
    }

    func testHooksRejectsMalformedJSON() async throws {
        let (status, _) = try await postRaw("/hooks?token=\(Self.workerToken)", headers: [:], body: Data("{not json".utf8))
        XCTAssertEqual(status, 400)
        let events = await hooks.events
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: MCP initialize / ping / method routing

    func testInitializeEchoesSupportedProtocolVersionAndSetsSessionHeader() async throws {
        let (status, json, headers) = try await mcpWithHeaders(
            rpc("initialize", id: 1, params: ["protocolVersion": "2024-11-05", "capabilities": [:], "clientInfo": ["name": "test", "version": "0"]]),
            token: Self.workerToken
        )
        XCTAssertEqual(status, 200)
        let result = (json as? [String: Any])?["result"] as? [String: Any]
        XCTAssertEqual(result?["protocolVersion"] as? String, "2024-11-05")
        XCTAssertEqual((result?["capabilities"] as? [String: Any])?.keys.sorted(), ["tools"])
        let info = result?["serverInfo"] as? [String: String]
        XCTAssertEqual(info, ["name": "agent-board", "version": "0.1.0"])
        XCTAssertFalse((headers["Mcp-Session-Id"] ?? "").isEmpty)
        XCTAssertEqual(headers["Content-Type"], "application/json")
    }

    func testInitializeFallsBackToLatestForUnknownVersion() async throws {
        let (_, json) = try await mcp(rpc("initialize", id: "init", params: ["protocolVersion": "1999-01-01"]), token: Self.workerToken)
        let envelope = json as? [String: Any]
        XCTAssertEqual(envelope?["id"] as? String, "init")
        XCTAssertEqual((envelope?["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-06-18")
    }

    func testPingReturnsEmptyResult() async throws {
        let (status, json, headers) = try await mcpWithHeaders(rpc("ping", id: 7), token: Self.workerToken)
        XCTAssertEqual(status, 200)
        let envelope = json as? [String: Any]
        XCTAssertEqual(envelope?["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(envelope?["id"] as? Int, 7)
        XCTAssertEqual((envelope?["result"] as? [String: Any])?.count, 0)
        XCTAssertNil(headers["Mcp-Session-Id"])
    }

    func testUnknownMethodIsMethodNotFound() async throws {
        let (status, json) = try await mcp(rpc("server/discover", id: 3), token: Self.workerToken)
        XCTAssertEqual(status, 200)
        let error = (json as? [String: Any])?["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? Int, -32601)
        XCTAssertNil((json as? [String: Any])?["result"])
    }

    func testNotificationAloneIsAccepted() async throws {
        let (status, data) = try await mcpData(["jsonrpc": "2.0", "method": "notifications/initialized"], token: Self.workerToken)
        XCTAssertEqual(status, 202)
        XCTAssertTrue(data.isEmpty)
    }

    func testBatchOfPingAndNotificationYieldsOneElementArray() async throws {
        let batch: [Any] = [rpc("ping", id: 1), ["jsonrpc": "2.0", "method": "notifications/initialized"]]
        let (status, json) = try await mcp(batch, token: Self.workerToken)
        XCTAssertEqual(status, 200)
        let array = json as? [[String: Any]]
        XCTAssertEqual(array?.count, 1)
        XCTAssertEqual(array?[0]["id"] as? Int, 1)
        XCTAssertEqual((array?[0]["result"] as? [String: Any])?.count, 0)
    }

    func testUnparseableBodyIsParseError() async throws {
        let (status, data) = try await postRaw("/mcp", headers: ["Authorization": "Bearer \(Self.workerToken)"], body: Data("[".utf8))
        XCTAssertEqual(status, 400)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual((json?["error"] as? [String: Any])?["code"] as? Int, -32700)
    }

    func testGetMCPIsMethodNotAllowed() async throws {
        var request = URLRequest(url: url("/mcp"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(Self.workerToken)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 405)
    }

    func testDeleteMCPIsOK() async throws {
        var request = URLRequest(url: url("/mcp"))
        request.httpMethod = "DELETE"
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    // MARK: tools/list

    func testToolsListRendersHandlerDescriptorsForWorker() async throws {
        let (_, json) = try await mcp(rpc("tools/list", id: 1), token: Self.workerToken)
        let tools = ((json as? [String: Any])?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.count, FakeToolHandler.workerTools.count)
        XCTAssertEqual(tools?.map { $0["name"] as? String }, ["get_my_task", "log_progress"])
        XCTAssertEqual(tools?[1]["description"] as? String, "Append progress")
        let schema = tools?[1]["inputSchema"] as? [String: Any]
        XCTAssertEqual(schema?["type"] as? String, "object")
        XCTAssertEqual(schema?["required"] as? [String], ["text"])
        let textProperty = (schema?["properties"] as? [String: Any])?["text"] as? [String: Any]
        XCTAssertEqual(textProperty?["type"] as? String, "string")
        XCTAssertEqual(textProperty?["maxLength"] as? Int, 4000)
        XCTAssertEqual(Set(tools?[0].keys.map { $0 } ?? []), ["name", "description", "inputSchema"])
    }

    func testToolsListDiffersPerScope() async throws {
        let (_, workerJSON) = try await mcp(rpc("tools/list", id: 1), token: Self.workerToken)
        let (_, orchestratorJSON) = try await mcp(rpc("tools/list", id: 2), token: Self.orchestratorToken)
        let workerNames = toolNames(workerJSON)
        let orchestratorNames = toolNames(orchestratorJSON)
        XCTAssertEqual(workerNames, ["get_my_task", "log_progress"])
        XCTAssertEqual(orchestratorNames, ["get_my_task", "log_progress", "list_tasks"])
        XCTAssertLessThan(workerNames.count, orchestratorNames.count)
    }

    // MARK: tools/call

    func testToolsCallPassesArgumentsThroughAndReturnsText() async throws {
        let arguments: [String: Any] = ["text": "hello", "count": 3, "ratio": 0.5, "flag": true, "tags": ["a", "b"], "nested": ["k": NSNull()]]
        let (status, json) = try await mcp(rpc("tools/call", id: 9, params: ["name": "echo", "arguments": arguments]), token: Self.workerToken)
        XCTAssertEqual(status, 200)

        let calls = await tools.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "echo")
        XCTAssertEqual(calls[0].identity, Self.worker)
        XCTAssertEqual(calls[0].arguments, .object([
            "text": .string("hello"),
            "count": .number(3),
            "ratio": .number(0.5),
            "flag": .bool(true),
            "tags": .array([.string("a"), .string("b")]),
            "nested": .object(["k": .null]),
        ]))

        let result = (json as? [String: Any])?["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, false)
        let content = result?["content"] as? [[String: Any]]
        XCTAssertEqual(content?.count, 1)
        XCTAssertEqual(content?[0]["type"] as? String, "text")
        let text = content?[0]["text"] as? String
        let echoed = try JSONDecoder().decode(JSONValue.self, from: Data((text ?? "").utf8))
        XCTAssertEqual(echoed, calls[0].arguments)
    }

    func testToolsCallWithoutArgumentsPassesEmptyObject() async throws {
        _ = try await mcp(rpc("tools/call", id: 1, params: ["name": "echo"]), token: Self.orchestratorToken)
        let calls = await tools.calls
        XCTAssertEqual(calls.first?.arguments, .object([:]))
        XCTAssertEqual(calls.first?.identity, Self.orchestrator)
    }

    func testToolErrorBecomesIsErrorResultWithMessage() async throws {
        let (status, json) = try await mcp(rpc("tools/call", id: 2, params: ["name": "fail", "arguments": [:]]), token: Self.workerToken)
        XCTAssertEqual(status, 200)
        let envelope = json as? [String: Any]
        XCTAssertNil(envelope?["error"])
        let result = envelope?["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, true)
        let content = result?["content"] as? [[String: Any]]
        XCTAssertEqual(content?[0]["text"] as? String, "task 42 is not assignable")
    }

    func testHandlerIsErrorResultIsPreserved() async throws {
        let (_, json) = try await mcp(rpc("tools/call", id: 2, params: ["name": "soft_error"]), token: Self.workerToken)
        let result = ((json as? [String: Any])?["result"] as? [String: Any])
        XCTAssertEqual(result?["isError"] as? Bool, true)
        XCTAssertEqual((result?["content"] as? [[String: Any]])?[0]["text"] as? String, "handled softly")
    }

    func testUnexpectedErrorBecomesInternalJSONRPCError() async throws {
        let (status, json) = try await mcp(rpc("tools/call", id: 5, params: ["name": "crash"]), token: Self.workerToken)
        XCTAssertEqual(status, 200)
        let error = (json as? [String: Any])?["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? Int, -32603)
        XCTAssertEqual(error?["message"] as? String, "database exploded")
    }

    func testToolsCallWithoutNameIsInvalidParams() async throws {
        let (_, json) = try await mcp(rpc("tools/call", id: 5, params: ["arguments": [:]]), token: Self.workerToken)
        let error = (json as? [String: Any])?["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? Int, -32602)
        let calls = await tools.calls
        XCTAssertTrue(calls.isEmpty)
    }

    // MARK: Helpers

    private func url(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    private func rpc(_ method: String, id: Any, params: [String: Any]? = nil) -> [String: Any] {
        var message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { message["params"] = params }
        return message
    }

    private func toolNames(_ json: Any) -> [String] {
        let tools = ((json as? [String: Any])?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        return tools?.compactMap { $0["name"] as? String } ?? []
    }

    private func postRaw(_ path: String, headers: [String: String], body: Data) async throws -> (Int, Data, [String: String]) {
        var request = URLRequest(url: url(path))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as! HTTPURLResponse
        var responseHeaders: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                responseHeaders[key] = value
            }
        }
        return (http.statusCode, data, responseHeaders)
    }

    private func postRaw(_ path: String, headers: [String: String], body: Data) async throws -> (Int, Data) {
        let (status, data, _): (Int, Data, [String: String]) = try await postRaw(path, headers: headers, body: body)
        return (status, data)
    }

    private func post(_ path: String, headers: [String: String], body: Any) async throws -> (Int, Any) {
        let (status, data) = try await postRaw(path, headers: headers, body: JSONSerialization.data(withJSONObject: body))
        return (status, try JSONSerialization.jsonObject(with: data))
    }

    private func mcpRaw(_ body: Any, token: String) async throws -> (Int, Any) {
        try await post("/mcp", headers: ["Authorization": "Bearer \(token)"], body: body)
    }

    private func mcp(_ body: Any, token: String) async throws -> (Int, Any) {
        try await mcpRaw(body, token: token)
    }

    private func mcpData(_ body: Any, token: String) async throws -> (Int, Data) {
        try await postRaw("/mcp", headers: ["Authorization": "Bearer \(token)"], body: JSONSerialization.data(withJSONObject: body))
    }

    private func mcpWithHeaders(_ body: Any, token: String) async throws -> (Int, Any, [String: String]) {
        let (status, data, headers): (Int, Data, [String: String]) = try await postRaw(
            "/mcp", headers: ["Authorization": "Bearer \(token)"], body: JSONSerialization.data(withJSONObject: body)
        )
        return (status, try JSONSerialization.jsonObject(with: data), headers)
    }
}
