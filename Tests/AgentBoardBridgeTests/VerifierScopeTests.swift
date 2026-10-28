import AgentBoardBridge
import AgentBoardCore
import AgentBoardServer
import Foundation
import XCTest

/// SPEC §6 Verifier scope, over the real HTTP server and the real handlers the app wires, so what is
/// asserted here is what a Walk me through it session sees.
final class VerifierScopeTests: XCTestCase {
    private var f: BridgeFixture!
    private var server: BoardServer!
    private var port = 0
    private var watch: PRWatch!
    private var grant: TokenGrant!

    override func setUp() async throws {
        f = try BridgeFixture.make()
        server = BoardServer(
            tokens: StoreTokenResolver(db: f.db),
            hooks: f.hooks,
            tools: f.scoped,
            resources: CompositeResourceHandler([
                (NoteResourceURI.scheme, NoteResourceHandler(db: f.db)),
                (BriefingResourceURI.scheme, BriefingResourceHandler(db: f.db)),
            ]),
            prompts: BriefingPromptHandler()
        )
        port = try await server.start()
        watch = try PRWatchStore(f.db).upsert(projectId: f.project.id, snapshot: PRSnapshot(
            repoOwner: "example-org", repoName: "app", number: 42, url: "https://github.com/example-org/app/pull/42",
            title: "Add a widget", headRef: "feature/widget", headOid: String(repeating: "a", count: 40),
            baseRef: "main", items: []
        ))
        grant = try TokenGrantStore(f.db).issueVerifier(projectId: f.project.id, prWatchId: watch.id)
        try f.note("Ours", sections: [(heading: "H", body: "a listed note")])
    }

    override func tearDown() async throws {
        await server.stop()
        f = nil
    }

    func testTheSurfaceIsThreeToolsAndNoResourcesOrPrompts() async throws {
        let listed = try await rpcResult("tools/list")
        let tools = try XCTUnwrap(listed["tools"] as? [[String: Any]])
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }), ["propose_task", "search_notes", "read_note"])
        XCTAssertEqual(tools.count, 3)
        let propose = try XCTUnwrap(tools.first { $0["name"] as? String == "propose_task" })
        let description = try XCTUnwrap(propose["description"] as? String)
        XCTAssertTrue(description.contains("Agent Board, the native macOS app"), description)
        XCTAssertTrue(description.contains("Proposed"), description)

        let resources = try await rpcResult("resources/list")
        XCTAssertEqual((resources["resources"] as? [Any])?.count, 0)
        let prompts = try await rpcResult("prompts/list")
        XCTAssertEqual((prompts["prompts"] as? [Any])?.count, 0)
    }

    func testProposeTaskLandsInProposedWithItsFieldsAndItsReportNamesThePullRequest() async throws {
        let result = try await callTool("propose_task", [
            "title": "Fix the widget's empty state", "body": "It shows a blank card.",
            "acceptance": "An empty list says so.", "type": "code", "rationale": "Found while verifying.",
        ])
        XCTAssertEqual(result["isError"] as? Bool, false, "\(result)")

        let task = try XCTUnwrap(f.tasks.list(projectId: f.project.id, column: .proposed).first)
        XCTAssertEqual(task.title, "Fix the widget's empty state")
        XCTAssertEqual(task.origin, .verifySession)
        XCTAssertEqual(task.acceptance, "An empty list says so.")
        XCTAssertEqual(task.type, .code)
        let report = try XCTUnwrap(f.reports.latest(taskId: task.id))
        XCTAssertEqual(report.kind, .proposal)
        XCTAssertTrue(report.body.contains("example-org/app#42"), report.body)
        XCTAssertNil(report.sessionId)
    }

    func testAnInvalidTypeIsRefusedWithTheValidListAndWritesNothing() async throws {
        let result = try await callTool("propose_task", ["title": "t", "type": "chore"])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let text = try toolText(result)
        for type in TaskType.allCases { XCTAssertTrue(text.contains(type.rawValue), text) }
        XCTAssertEqual(try f.tasks.list(projectId: f.project.id, column: .proposed), [])
    }

    func testARevokedVerifierTokenIsRefusedOnMCP() async throws {
        try TokenGrantStore(f.db).revokeVerifierGrants()
        let (_, status) = try await rpc("tools/list")
        XCTAssertEqual(status, 401)
    }

    func testAHookPostWithAVerifierTokenChangesNoRow() async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/hooks?token=\(grant.token)")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"hook_event_name":"SessionStart","session_id":"human-claude","source":"startup"}"#.utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        XCTAssertNil(try TokenGrantStore(f.db).lookup(token: grant.token)?.sessionId)
        XCTAssertNil(try f.hookEvents.mostRecent(sessionId: "human-claude", event: "SessionStart"))
        XCTAssertNil(try f.sessions.get("human-claude"))
    }

    private func callTool(_ name: String, _ arguments: [String: Any]) async throws -> [String: Any] {
        try await rpcResult("tools/call", params: ["name": name, "arguments": arguments])
    }

    private func toolText(_ result: [String: Any]) throws -> String {
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return try XCTUnwrap(content.first?["text"] as? String)
    }

    private func rpcResult(_ method: String, params: [String: Any]? = nil) async throws -> [String: Any] {
        let (json, status) = try await rpc(method, params: params)
        XCTAssertEqual(status, 200)
        if let error = json["error"] { XCTFail("\(method) failed: \(error)") }
        return try XCTUnwrap(json["result"] as? [String: Any])
    }

    private func rpc(_ method: String, params: [String: Any]? = nil) async throws -> ([String: Any], Int) {
        var message: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method]
        if let params { message["params"] = params }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(grant.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: message)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return (json, status)
    }
}
