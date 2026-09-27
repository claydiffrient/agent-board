import AgentBoardBridge
import AgentBoardCore
import AgentBoardServer
import Foundation
import XCTest

/// SPEC §6: the orchestrator sets, reads and clears a task's `type` over the real HTTP server.
final class TaskTypeToolTests: XCTestCase {
    private var f: BridgeFixture!
    private var server: BoardServer!
    private var port = 0

    override func setUp() async throws {
        f = try BridgeFixture.make()
        server = BoardServer(
            tokens: InMemoryTokenResolver([f.orchestratorIdentity]),
            hooks: f.hooks,
            tools: f.scoped
        )
        port = try await server.start()
    }

    override func tearDown() async throws {
        await server.stop()
    }

    func testTypeIsSetReadClearedAndValidated() async throws {
        let created = try await callJSON("create_task", ["title": "Write the plan", "type": "plan"])
        let id = try XCTUnwrap(created["id"] as? String)

        let detail = try await callJSON("get_task", ["id": id])
        XCTAssertEqual(detail["type"] as? String, "plan")
        let list = try await callJSONArray("list_tasks", [:])
        XCTAssertEqual(list.first { $0["id"] as? String == id }?["type"] as? String, "plan")

        _ = try await call("update_task", ["id": id, "type": ""])
        let cleared = try await callJSON("get_task", ["id": id])
        XCTAssertTrue(cleared["type"] is NSNull, "\"\" did not clear the type")

        let refused = try await call("create_task", ["title": "Ship it", "type": "chore"])
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.text.contains("code, docs, tests, plan, review"), refused.text)
    }

    func testCreateEpicSetsEachTasksType() async throws {
        let created = try await callJSON("create_epic", [
            "title": "Docs pass", "tasks": [["title": "Write the guide", "type": "docs"]],
        ])
        let id = try XCTUnwrap((created["task_ids"] as? [String])?.first)
        let detail = try await callJSON("get_task", ["id": id])
        XCTAssertEqual(detail["type"] as? String, "docs")
    }

    // MARK: Helpers

    private func callJSON(_ name: String, _ arguments: [String: Any]) async throws -> [String: Any] {
        let result = try await call(name, arguments)
        XCTAssertFalse(result.isError, result.text)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any])
    }

    private func callJSONArray(_ name: String, _ arguments: [String: Any]) async throws -> [[String: Any]] {
        let result = try await call(name, arguments)
        XCTAssertFalse(result.isError, result.text)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [[String: Any]])
    }

    private func call(_ name: String, _ arguments: [String: Any]) async throws -> (text: String, isError: Bool) {
        let message: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": arguments],
        ]
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(f.orchestratorIdentity.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: message)
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(json["result"] as? [String: Any], "\(name) failed: \(json)")
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return (try XCTUnwrap(content.first?["text"] as? String), result["isError"] as? Bool ?? false)
    }
}
