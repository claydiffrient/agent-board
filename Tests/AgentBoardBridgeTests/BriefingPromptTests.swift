import AgentBoardBridge
import AgentBoardCore
import AgentBoardServer
import Foundation
import XCTest

/// Exercises `prompts/list` and `prompts/get` over the real HTTP server with the real handler, so
/// the shapes asserted here are the shapes a session sees.
final class BriefingPromptTests: XCTestCase {
    private static let token = "prompt-token"
    private static let identity = TokenIdentity(
        token: token, scope: .worker, projectId: "p1", sessionId: "s1", taskId: "t1"
    )

    private var server: BoardServer!
    private var port = 0

    override func setUp() async throws {
        server = BoardServer(
            tokens: InMemoryTokenResolver([Self.identity]),
            hooks: SilentHookSink(),
            tools: EmptyToolHandler(),
            prompts: BriefingPromptHandler()
        )
        port = try await server.start()
    }

    override func tearDown() async throws {
        await server.stop()
    }

    func testInitializeAdvertisesPrompts() async throws {
        let result = try await rpcResult("initialize", params: ["protocolVersion": "2025-06-18"])
        let capabilities = try XCTUnwrap(result["capabilities"] as? [String: Any])
        XCTAssertNotNil(capabilities["prompts"], "capabilities were \(capabilities.keys.sorted())")
        XCTAssertEqual(capabilities["prompts"] as? [String: Bool], ["listChanged": false])
        XCTAssertNotNil(capabilities["tools"])
    }

    func testListReturnsEveryPromptWithItsDeclaredArguments() async throws {
        let result = try await rpcResult("prompts/list")
        let prompts = try XCTUnwrap(result["prompts"] as? [[String: Any]])
        XCTAssertEqual(prompts.compactMap { $0["name"] as? String }, ["wind_down_order", "worker_protocol"])

        for prompt in prompts {
            let name = try XCTUnwrap(prompt["name"] as? String)
            XCTAssertFalse((prompt["description"] as? String ?? "").isEmpty, "\(name) has no description")
            XCTAssertFalse((prompt["title"] as? String ?? "").isEmpty, "\(name) has no title")
            let arguments = try XCTUnwrap(prompt["arguments"] as? [[String: Any]], "\(name) declares no arguments")
            XCTAssertFalse(arguments.isEmpty, "\(name) declares an empty argument list")
            for argument in arguments {
                XCTAssertFalse((argument["name"] as? String ?? "").isEmpty, "\(name) has an unnamed argument")
                XCTAssertFalse((argument["description"] as? String ?? "").isEmpty, "\(name) has an undescribed argument")
                XCTAssertNotNil(argument["required"] as? Bool, "\(name) does not say whether an argument is required")
            }
        }

        let windDown = try XCTUnwrap(prompts.first { $0["name"] as? String == "wind_down_order" })
        let windDownArguments = try XCTUnwrap(windDown["arguments"] as? [[String: Any]])
        XCTAssertEqual(
            windDownArguments.map { [$0["name"] as? String ?? "", String(describing: $0["required"] as? Bool ?? false)] },
            [["via", "true"], ["reason", "false"]]
        )
    }

    /// The anti-drift assertion: the prompt is not a second copy of the wind-down text, it is the
    /// same function. Editing `windDownOrder` cannot change one without the other.
    func testGettingTheWindDownOrderMatchesWhatTheSwiftAssemblyProduces() async throws {
        let result = try await rpcResult(
            "prompts/get",
            params: ["name": "wind_down_order", "arguments": ["via": "hook", "reason": "end of the day"]]
        )
        let messages = try XCTUnwrap(result["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        let content = try XCTUnwrap(messages[0]["content"] as? [String: Any])
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        XCTAssertEqual(content["type"] as? String, "text")
        XCTAssertEqual(
            content["text"] as? String,
            ShutdownOrder.windDownOrder(reason: "end of the day", via: .hook)
        )
        XCTAssertFalse((result["description"] as? String ?? "").isEmpty)
    }

    func testTheOmittedOptionalArgumentGivesTheSameTextAsANilReason() async throws {
        let result = try await rpcResult("prompts/get", params: ["name": "wind_down_order", "arguments": ["via": "resume"]])
        let text = try promptText(result)
        XCTAssertEqual(text, ShutdownOrder.windDownOrder(reason: nil, via: .resume))
        XCTAssertFalse(text.contains("Reason:"))
    }

    func testGettingTheWorkerProtocolMatchesTheTailOfTheOpeningPrompt() async throws {
        let result = try await rpcResult(
            "prompts/get",
            params: ["name": "worker_protocol", "arguments": ["branch": "agentboard/abc123"]]
        )
        let text = try promptText(result)
        XCTAssertEqual(text, OpeningPrompt.workingProtocol(branch: "agentboard/abc123"))

        let spawned = OpeningPrompt.compose(
            task: BoardTask(
                id: "t1", projectId: "p1", epicId: nil, title: "Do the thing", body: "Body",
                acceptance: "Criteria", priority: nil, column: .running, ordering: 1,
                origin: .orchestrator, createdAt: 0, updatedAt: 0
            ),
            branch: "agentboard/abc123",
            attempt: 1
        )
        XCTAssertTrue(spawned.hasSuffix(text), "the prompt text is no longer what a worker is spawned with")
    }

    func testAMissingRequiredArgumentIsRefused() async throws {
        let error = try await rpcError("prompts/get", params: ["name": "wind_down_order", "arguments": ["reason": "spend"]])
        XCTAssertEqual(error["code"] as? Int, -32602)
        XCTAssertTrue((error["message"] as? String ?? "").contains("via"), "message was \(error["message"] ?? "")")

        let noArguments = try await rpcError("prompts/get", params: ["name": "worker_protocol"])
        XCTAssertEqual(noArguments["code"] as? Int, -32602)
        XCTAssertTrue((noArguments["message"] as? String ?? "").contains("branch"))
    }

    func testAnUnknownPromptAndAnUnknownArgumentValueAreRefused() async throws {
        let unknown = try await rpcError("prompts/get", params: ["name": "no_such_prompt", "arguments": [String: String]()])
        XCTAssertEqual(unknown["code"] as? Int, -32602)

        let badVia = try await rpcError("prompts/get", params: ["name": "wind_down_order", "arguments": ["via": "telepathy"]])
        XCTAssertEqual(badVia["code"] as? Int, -32602)
    }

    // MARK: Helpers

    private func promptText(_ result: [String: Any]) throws -> String {
        let messages = try XCTUnwrap(result["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? [String: Any])
        return try XCTUnwrap(content["text"] as? String)
    }

    private func rpcResult(_ method: String, params: [String: Any]? = nil) async throws -> [String: Any] {
        let json = try await rpc(method, params: params)
        if let error = json["error"] { XCTFail("\(method) failed: \(error)") }
        return try XCTUnwrap(json["result"] as? [String: Any])
    }

    private func rpcError(_ method: String, params: [String: Any]? = nil) async throws -> [String: Any] {
        let json = try await rpc(method, params: params)
        XCTAssertNil(json["result"], "\(method) unexpectedly succeeded")
        return try XCTUnwrap(json["error"] as? [String: Any])
    }

    private func rpc(_ method: String, params: [String: Any]?) async throws -> [String: Any] {
        var message: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method]
        if let params { message["params"] = params }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(Self.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: message)
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private struct SilentHookSink: HookSink {
    func handle(_ event: HookEvent, identity: TokenIdentity) async -> HookDecision? { nil }
}

private struct EmptyToolHandler: ToolHandler {
    func tools(for identity: TokenIdentity) async -> [ToolDescriptor] { [] }

    func call(_ name: String, arguments: JSONValue, identity: TokenIdentity) async throws -> ToolResult {
        throw ToolError("no tools")
    }
}
