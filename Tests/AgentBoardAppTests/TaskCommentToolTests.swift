import AgentBoardCore
import Foundation
import XCTest
@testable import AgentBoard

/// SPEC §6: every scope reads and writes a task's comment thread over MCP, signed from its token.
/// Real supervisor, real board server over HTTP, real git worktrees, fake claude.
@MainActor
final class TaskCommentToolTests: XCTestCase {
    private var fixture: SupervisorFixture!

    override func setUp() async throws {
        fixture = try SupervisorFixture.make(gitRepo: true)
        await fixture.supervisor.start()
        try XCTSkipIf(fixture.supervisor.serverPort == nil, "the board server could not bind a port")
    }

    override func tearDown() async throws {
        await fixture.supervisor.waitForSetup()
        fixture.cleanUp()
        fixture = nil
    }

    func testEveryScopeCommentsAsItsTokenAndTheThreadComesBackInOrder() async throws {
        let rita = try RosterStore(fixture.db).create(
            name: "Rita", role: "reviewer", systemPrompt: "You review for correctness."
        )
        try RosterStore(fixture.db).enable(agentId: rita.id, forProject: fixture.project.id)
        let parser = try readyTask("Add the parser")
        let other = try readyTask("Add the lexer")
        let orchestrator = try fixture.grants.issue(projectId: fixture.project.id, scope: .orchestrator, taskId: nil)
        let (worker, workerToken) = try await spawnWorker(on: parser)
        let (_, otherToken) = try await spawnWorker(on: other)

        _ = try await call("add_comment", ["task_id": parser.id, "body": "Keep the grammar LL(1)."], token: orchestrator.token)
        _ = try await call("add_comment", ["body": "  Left recursion removed in expr.  ", "author_name": "Clay"], token: workerToken)

        let refused = try await callRaw(
            "add_comment", ["task_id": parser.id, "body": "I think this is wrong."], token: otherToken
        )
        XCTAssertTrue(refused.isError, "a worker bound to another task commented on this one")
        XCTAssertTrue(refused.text.contains("not your task"), refused.text)

        try fixture.commitInto(worker.cwd, file: "parser.txt")
        _ = try fixture.board.complete(taskId: parser.id, sessionId: worker.sessionId, summary: "done")
        _ = try await fixture.supervisor.assignAgent(taskId: parser.id, rosterAgentId: rita.id, scope: .reviewer)
        await fixture.supervisor.waitForSetup()
        let reviewer = try XCTUnwrap(fixture.sessions.forTask(parser.id).first { $0.rosterAgentId == rita.id })
        let reviewerToken = try XCTUnwrap(fixture.grants.forSession(reviewer.sessionId).first).token

        _ = try await call("add_comment", ["body": "The empty-input case needs a test."], token: reviewerToken)
        let review = try await call("get_my_task", [:], token: reviewerToken)
        XCTAssertEqual((review["comments"] as? [Any])?.count, 3, "the reviewer does not see the thread")
        _ = try await call("accept_task", ["verdict": "Ran the parser tests; they pass."], token: reviewerToken)
        XCTAssertEqual(try fixture.tasks.get(parser.id, includeArchived: true)?.column, .done,
                       "a reviewer's comment tripped the verdict check")

        let detail = try await call("get_task", ["id": parser.id], token: orchestrator.token)
        let thread = try XCTUnwrap(detail["comments"] as? [[String: Any]])
        XCTAssertEqual(thread.map { $0["author_kind"] as? String }, ["orchestrator", "worker", "reviewer"])
        XCTAssertEqual(
            thread.map { $0["author_name"] as? String },
            ["Orchestrator", "Worker \(try XCTUnwrap(worker.shortId))", "Rita"]
        )
        XCTAssertEqual(thread.map { $0["roster_agent"] as? String }, [nil, nil, "Rita"])
        XCTAssertEqual(thread[1]["body"] as? String, "Left recursion removed in expr.")
        let times = try thread.map { try XCTUnwrap(ISO8601DateFormatter.fractional.date(from: $0["created_at"] as? String ?? "")) }
        XCTAssertEqual(times, times.sorted())
        XCTAssertEqual(try CommentStore(fixture.db).list(taskId: other.id), [])

        let workerView = try await call("get_my_task", [:], token: otherToken)
        XCTAssertEqual((workerView["comments"] as? [Any])?.count, 0, "another task's thread leaked into this one")
    }

    private func readyTask(_ title: String) throws -> BoardTask {
        try fixture.tasks.create(
            projectId: fixture.project.id, title: title, body: nil, acceptance: nil,
            priority: nil, column: .ready, origin: .human, epicId: nil
        )
    }

    private func spawnWorker(on task: BoardTask) async throws -> (AgentSession, String) {
        try await fixture.supervisor.assign(taskId: task.id)
        await fixture.supervisor.waitForSetup()
        let session = try XCTUnwrap(fixture.sessions.forTask(task.id).last)
        return (session, try XCTUnwrap(fixture.grants.forSession(session.sessionId).first).token)
    }

    private func call(_ name: String, _ arguments: [String: Any], token: String) async throws -> [String: Any] {
        let result = try await callRaw(name, arguments, token: token)
        XCTAssertFalse(result.isError, "\(name) failed: \(result.text)")
        return (try? JSONSerialization.jsonObject(with: Data(result.text.utf8))) as? [String: Any] ?? [:]
    }

    private func callRaw(
        _ name: String, _ arguments: [String: Any], token: String
    ) async throws -> (isError: Bool, text: String) {
        let port = try XCTUnwrap(fixture.supervisor.serverPort)
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/mcp")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": name, "arguments": arguments],
        ])
        let (data, _) = try await URLSession.shared.data(for: request)
        let envelope = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(envelope["result"] as? [String: Any], "no result in \(envelope)")
        let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        return (result["isError"] as? Bool ?? false, text)
    }
}

private extension ISO8601DateFormatter {
    static var fractional: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
