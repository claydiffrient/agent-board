import AgentBoardServer
import Foundation
import XCTest

final class BoardServerResourceTests: XCTestCase {
    private static let token = "worker-token-1"
    private static let worker = TokenIdentity(token: token, scope: .worker, projectId: "p1", sessionId: "s1", taskId: "t1")

    private var server: BoardServer!
    private var resources: FakeResourceHandler!
    private var port = 0

    override func setUp() async throws {
        resources = FakeResourceHandler()
        server = BoardServer(
            tokens: InMemoryTokenResolver([Self.worker]),
            hooks: RecordingHookSink(),
            tools: FakeToolHandler(),
            resources: resources
        )
        port = try await server.start()
    }

    override func tearDown() async throws {
        await server.stop()
    }

    // MARK: Capability

    func testInitializeAdvertisesResourcesAlongsideTools() async throws {
        let result = try await result(of: rpc("initialize", id: 1, params: ["protocolVersion": "2025-06-18"]))
        let capabilities = try XCTUnwrap(result["capabilities"] as? [String: Any])
        XCTAssertEqual(capabilities.keys.sorted(), ["resources", "tools"])
        XCTAssertEqual((capabilities["resources"] as? [String: Any])?.count, 0, "neither subscribe nor listChanged is supported")
    }

    func testAServerWithNoResourceHandlerAdvertisesToolsOnlyAndRefusesTheResourceMethods() async throws {
        let bare = BoardServer(tokens: InMemoryTokenResolver([Self.worker]), hooks: RecordingHookSink(), tools: FakeToolHandler())
        let barePort = try await bare.start()
        defer { Task { await bare.stop() } }

        let initialized = try await result(of: rpc("initialize", id: 1, params: [:]), port: barePort)
        XCTAssertEqual((initialized["capabilities"] as? [String: Any])?.keys.sorted(), ["tools"])

        for method in ["resources/list", "resources/read", "resources/templates/list"] {
            let envelope = try await send(rpc(method, id: 2, params: ["uri": "note://p1/n1"]), port: barePort)
            XCTAssertEqual((envelope["error"] as? [String: Any])?["code"] as? Int, -32601, method)
        }
    }

    // MARK: resources/list

    func testListRendersTheMCPResourceFields() async throws {
        let result = try await result(of: rpc("resources/list", id: 2))
        let listed = try XCTUnwrap(result["resources"] as? [[String: Any]])
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0]["uri"] as? String, "note://p1/n1")
        XCTAssertEqual(listed[0]["name"] as? String, "Build gotchas")
        XCTAssertEqual(listed[0]["mimeType"] as? String, "application/json")
        XCTAssertEqual(listed[0]["description"] as? String, "2 sections: The trap · What to do. Version 3, updated 2026-09-14.")
        XCTAssertNil(result["nextCursor"], "the whole listing is one page")
    }

    func testTemplateListIsEmptyRatherThanMissing() async throws {
        let result = try await result(of: rpc("resources/templates/list", id: 3))
        XCTAssertEqual((result["resourceTemplates"] as? [Any])?.count, 0)
    }

    // MARK: resources/read

    func testReadReturnsTheBodyAsTextContents() async throws {
        await resources.put(uri: "note://p1/n1", body: #"{"title":"Build gotchas"}"#)
        let result = try await result(of: rpc("resources/read", id: 4, params: ["uri": "note://p1/n1"]))
        let contents = try XCTUnwrap(result["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.count, 1)
        XCTAssertEqual(contents[0]["uri"] as? String, "note://p1/n1")
        XCTAssertEqual(contents[0]["mimeType"] as? String, "application/json")
        XCTAssertEqual(contents[0]["text"] as? String, #"{"title":"Build gotchas"}"#)
    }

    func testAnUnknownUriIsResourceNotFoundRatherThanEmptyContents() async throws {
        let envelope = try await send(rpc("resources/read", id: 5, params: ["uri": "note://p1/nope"]))
        XCTAssertNil(envelope["result"])
        let error = try XCTUnwrap(envelope["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32002)
        XCTAssertEqual((error["data"] as? [String: Any])?["uri"] as? String, "note://p1/nope")
        XCTAssertTrue((error["message"] as? String ?? "").contains("note://p1/nope"))
    }

    func testReadWithoutAUriIsInvalidParams() async throws {
        let envelope = try await send(rpc("resources/read", id: 6, params: [:]))
        XCTAssertEqual((envelope["error"] as? [String: Any])?["code"] as? Int, -32602)
        let reads = await resources.reads
        XCTAssertTrue(reads.isEmpty)
    }

    func testResourceMethodsRequireABearerToken() async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: rpc("resources/list", id: 7))
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401)
        let reads = await resources.reads
        XCTAssertTrue(reads.isEmpty)
    }

    // MARK: Helpers

    private func rpc(_ method: String, id: Any, params: [String: Any]? = nil) -> [String: Any] {
        var message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { message["params"] = params }
        return message
    }

    private func send(_ body: [String: Any], port: Int? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port ?? self.port)/mcp")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(Self.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func result(of body: [String: Any], port: Int? = nil) async throws -> [String: Any] {
        let envelope = try await send(body, port: port)
        XCTAssertNil(envelope["error"], "\(envelope)")
        return try XCTUnwrap(envelope["result"] as? [String: Any])
    }
}
