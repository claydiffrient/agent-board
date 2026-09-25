import AgentBoardCore
import Foundation
import GRDB
import XCTest
@testable import AgentBoard

/// SPEC §8.2: the Coordinator reads every project's board and writes to none, and its own queue is
/// nobody else's. Real supervisor, the app's own tool wiring, real grants over HTTP.
@MainActor
final class CoordinatorBoardAccessTests: XCTestCase {
    private var fixture: SupervisorFixture!

    override func setUp() async throws {
        fixture = try SupervisorFixture.make()
        await fixture.supervisor.start()
        try XCTSkipIf(fixture.supervisor.serverPort == nil, "the board server could not bind a port")
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    func testTheCoordinatorReadsEveryBoardWritesNoneAndLeavesProjectIsolationAsItWas() async throws {
        let a = fixture.project
        let b = try ProjectStore(fixture.db).register(
            name: "Infra", repoPath: fixture.supportDir.appendingPathComponent("infra").path,
            baseBranch: "main", worktreeRoot: fixture.supportDir.appendingPathComponent("infra-wt").path, memoryDir: nil
        )
        let parser = try fixture.tasks.create(
            projectId: a.id, title: "Add the parser", body: nil, acceptance: nil, priority: nil,
            column: .review, origin: .human, epicId: nil
        )
        try CommentStore(fixture.db).add(taskId: parser.id, author: CommentAuthor(kind: .human, name: "Clay"), body: "Keep it LL(1).")
        try fixture.reports.insert(projectId: a.id, taskId: parser.id, sessionId: nil, kind: .complete, body: "Parser landed.")
        let queuedForA = try fixture.reports.unconsumedCount(projectId: a.id)
        let aNote = try NoteStore(fixture.db).create(projectId: a.id, title: "Grammar", sections: [(heading: "Rule", body: "LL(1)")])
        let bEpic = Epic(
            id: Epic.newId(), projectId: b.id, title: "Move DNS", goal: nil,
            branch: EpicStore.branchPrefix + "dns", state: .pullRequestOpen, createdAt: .nowMillis
        )
        try await fixture.db.writer.write { db in try bEpic.insert(db) }
        let deploy = try fixture.tasks.create(
            projectId: b.id, title: "Cut over", body: nil, acceptance: nil, priority: nil,
            column: .ready, origin: .human, epicId: bEpic.id
        )
        let published = try fixture.approvals.create(
            projectId: b.id, kind: .pullRequest, taskId: nil, epicId: bEpic.id, requestedBy: "orch", reason: nil
        )
        try await fixture.db.writer.write { db in
            try db.execute(
                sql: "UPDATE approval SET resolved_at = 1, resolution = 'approved', published_url = ? WHERE id = ?",
                arguments: ["https://github.com/acme/infra/pull/42", published.id]
            )
        }
        try fixture.approvals.create(projectId: b.id, kind: .spawn, taskId: deploy.id, epicId: nil, requestedBy: "orch", reason: "cut over")
        try fixture.sessions.insert(AgentSession(
            sessionId: "w-infra", projectId: b.id, taskId: deploy.id, role: .worker, cwd: "/tmp", state: .running,
            estCostUSD: 1.25
        ))
        let bNote = try NoteStore(fixture.db).create(projectId: b.id, title: "Runbook", sections: [(heading: "DNS", body: "TTL 60")])

        let coordinator = try fixture.grants.issueCoordinator().token
        let orchestratorA = try fixture.grants.issue(projectId: a.id, scope: .orchestrator, taskId: nil).token

        let projects = try await call("list_projects", [:], token: coordinator) as? [[String: Any]]
        XCTAssertEqual(Set(projects?.compactMap { $0["name"] as? String } ?? []), ["Demo", "Infra"])

        let fetched = try await call("get_task", ["project_id": a.id, "id": parser.id], token: coordinator)
        let task = try XCTUnwrap(fetched as? [String: Any])
        XCTAssertEqual((task["latest_report"] as? [String: Any])?["body"] as? String, "Parser landed.")
        XCTAssertEqual((task["comments"] as? [[String: Any]])?.first?["body"] as? String, "Keep it LL(1).")
        let bTasks = try await call("list_tasks", ["project_id": b.id], token: coordinator) as? [[String: Any]]
        XCTAssertEqual(bTasks?.compactMap { $0["id"] as? String }, [deploy.id])

        let bEpics = try await call("list_epics", ["project_id": b.id], token: coordinator) as? [[String: Any]]
        XCTAssertEqual(bEpics?.first?["state"] as? String, "pull_request_open")
        XCTAssertEqual((bEpics?.first?["pull_request"] as? [String: Any])?["url"] as? String, "https://github.com/acme/infra/pull/42")
        let aEpics = try await call("list_epics", ["project_id": a.id], token: coordinator) as? [[String: Any]]
        XCTAssertEqual(aEpics?.count, 0)

        let aNotes = try await call("list_notes", ["project_id": a.id], token: coordinator) as? [[String: Any]]
        XCTAssertEqual(aNotes?.compactMap { $0["id"] as? String }, [aNote.id])
        let runbook = try await callRaw("read_note", ["project_id": b.id, "id": bNote.id], token: coordinator)
        XCTAssertFalse(runbook.isError, runbook.text)
        XCTAssertTrue(runbook.text.contains("TTL 60"), runbook.text)

        let agents = try await call("list_agents", ["project_id": b.id], token: coordinator) as? [[String: Any]]
        XCTAssertEqual(agents?.first { $0["session_id"] as? String == "w-infra" }?["est_cost_usd"] as? Double, 1.25)
        let approvals = try await call("list_approvals", ["project_id": b.id], token: coordinator) as? [[String: Any]]
        XCTAssertEqual(approvals?.compactMap { $0["reason"] as? String }, ["cut over"])

        let write = try await callRaw("create_task", ["project_id": a.id, "title": "Coordinator's idea"], token: coordinator)
        XCTAssertTrue(write.isError, write.text)
        XCTAssertTrue(write.text.contains("not a Coordinator tool"), write.text)
        XCTAssertEqual(try fixture.tasks.list(projectId: a.id).map(\.id), [parser.id])

        let inbox = try await callRaw("list_reports", ["project_id": a.id], token: coordinator)
        XCTAssertTrue(inbox.isError, inbox.text)
        XCTAssertTrue(inbox.text.contains("inbox"), inbox.text)
        XCTAssertEqual(try fixture.reports.unconsumedCount(projectId: a.id), queuedForA, "the Coordinator drained an orchestrator's queue")

        let foreign = try await callRaw("get_task", ["id": deploy.id], token: orchestratorA)
        XCTAssertTrue(foreign.isError, foreign.text)
        XCTAssertTrue(foreign.text.contains("not in this project"), foreign.text)
        let ownBoard = try await call("list_tasks", [:], token: orchestratorA) as? [[String: Any]]
        XCTAssertEqual(ownBoard?.compactMap { $0["id"] as? String }, [parser.id])

        let reply = try fixture.reports.insertForCoordinator(sessionId: nil, kind: .message, body: "Infra agrees.")
        let replyId = try XCTUnwrap(reply.id)
        let aQueue = try await call("list_reports", [:], token: orchestratorA) as? [[String: Any]]
        XCTAssertEqual(aQueue?.count, queuedForA)
        XCTAssertFalse(aQueue?.contains { $0["body"] as? String == "Infra agrees." } ?? true, "the Coordinator's reply reached a project")
        let peek = try await callRaw("get_report", ["id": replyId], token: orchestratorA)
        XCTAssertTrue(peek.isError, "an orchestrator read the Coordinator's queue: \(peek.text)")
        XCTAssertEqual(try fixture.reports.unconsumedForCoordinator().map(\.id), [replyId])

        XCTAssertEqual(try ProjectStore(fixture.db).list().map(\.id).sorted(), [a.id, b.id].sorted())
        let seenByOrchestrator = try await call("list_projects", [:], token: orchestratorA) as? [[String: Any]]
        XCTAssertEqual(seenByOrchestrator?.count, 2, "the Coordinator appeared as a project")
    }

    private func call(_ name: String, _ arguments: [String: Any], token: String) async throws -> Any? {
        let result = try await callRaw(name, arguments, token: token)
        XCTAssertFalse(result.isError, "\(name) failed: \(result.text)")
        return try? JSONSerialization.jsonObject(with: Data(result.text.utf8))
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
