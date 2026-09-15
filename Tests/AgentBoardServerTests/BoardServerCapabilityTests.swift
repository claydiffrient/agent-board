import AgentBoardServer
import Foundation
import XCTest

/// Resources and prompts are independent optional handlers, so `initialize` has four shapes and
/// each of the five methods is served or -32601 on its own handler. The single-handler rows are the
/// ones neither feature's own suite could cover.
final class BoardServerCapabilityTests: XCTestCase {
    private static let token = "worker-token-1"
    private static let worker = TokenIdentity(token: token, scope: .worker, projectId: "p1", sessionId: "s1", taskId: "t1")

    private static let resourceMethods = ["resources/list", "resources/read", "resources/templates/list"]
    private static let promptMethods = ["prompts/list", "prompts/get"]

    func testBothHandlersAdvertiseBothCapabilitiesAndServeAllFiveMethods() async throws {
        try await withServer(resources: FakeResourceHandler(), prompts: FakePromptHandler()) { port in
            let capabilities = try await self.capabilities(port: port)
            XCTAssertEqual(capabilities.keys.sorted(), ["prompts", "resources", "tools"])
            XCTAssertEqual((capabilities["resources"] as? [String: Any])?.count, 0)
            XCTAssertEqual(capabilities["prompts"] as? [String: Bool], ["listChanged": false])
            try await self.assertServed(Self.resourceMethods + Self.promptMethods, port: port)
        }
    }

    func testNeitherHandlerAdvertisesToolsOnlyAndRefusesAllFiveMethods() async throws {
        try await withServer(resources: nil, prompts: nil) { port in
            let capabilities = try await self.capabilities(port: port)
            XCTAssertEqual(capabilities.keys.sorted(), ["tools"])
            try await self.assertNotFound(Self.resourceMethods + Self.promptMethods, port: port)
        }
    }

    func testResourcesAloneAdvertiseResourcesAndLeavePromptMethodsUnserved() async throws {
        try await withServer(resources: FakeResourceHandler(), prompts: nil) { port in
            let capabilities = try await self.capabilities(port: port)
            XCTAssertEqual(capabilities.keys.sorted(), ["resources", "tools"])
            try await self.assertServed(Self.resourceMethods, port: port)
            try await self.assertNotFound(Self.promptMethods, port: port)
        }
    }

    func testPromptsAloneAdvertisePromptsAndLeaveResourceMethodsUnserved() async throws {
        try await withServer(resources: nil, prompts: FakePromptHandler()) { port in
            let capabilities = try await self.capabilities(port: port)
            XCTAssertEqual(capabilities.keys.sorted(), ["prompts", "tools"])
            try await self.assertServed(Self.promptMethods, port: port)
            try await self.assertNotFound(Self.resourceMethods, port: port)
        }
    }

    // MARK: Helpers

    private func withServer(
        resources: (any ResourceHandler)?,
        prompts: (any PromptHandler)?,
        _ body: (Int) async throws -> Void
    ) async throws {
        let server = BoardServer(
            tokens: InMemoryTokenResolver([Self.worker]),
            hooks: RecordingHookSink(),
            tools: FakeToolHandler(),
            resources: resources,
            prompts: prompts
        )
        let port = try await server.start()
        do {
            try await body(port)
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }

    private func capabilities(port: Int) async throws -> [String: Any] {
        let envelope = try await send("initialize", port: port, params: ["protocolVersion": "2025-06-18"])
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])
        return try XCTUnwrap(result["capabilities"] as? [String: Any])
    }

    /// A served method may still fail on its arguments; what it must not be is -32601.
    private func assertServed(_ methods: [String], port: Int) async throws {
        for method in methods {
            let code = try await errorCode(of: method, port: port)
            XCTAssertNotEqual(code, -32601, "\(method) should be served")
        }
    }

    private func assertNotFound(_ methods: [String], port: Int) async throws {
        for method in methods {
            let code = try await errorCode(of: method, port: port)
            XCTAssertEqual(code, -32601, "\(method) should not be served")
        }
    }

    private func errorCode(of method: String, port: Int) async throws -> Int? {
        let envelope = try await send(method, port: port, params: ["uri": "note://p1/n1", "name": "worker_protocol"])
        return (envelope["error"] as? [String: Any])?["code"] as? Int
    }

    private func send(_ method: String, port: Int, params: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(Self.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params]
        )
        let (data, _) = try await URLSession.shared.data(for: request)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
