import AgentBoardBridge
import AgentBoardCore
import AgentBoardServer
import Foundation
import XCTest

/// SPEC §6: a triager reads its own watch's open items and records their verdicts, and nothing else.
final class TriageScopeTests: XCTestCase {
    private var f: BridgeFixture!
    private var watches: PRWatchStore!

    override func setUpWithError() throws {
        f = try BridgeFixture.make()
        watches = PRWatchStore(f.db)
    }

    private func watch(_ number: Int, items: [String]) throws -> PRWatch {
        try watches.upsert(projectId: f.project.id, snapshot: PRSnapshot(
            repoOwner: "example-org", repoName: "app", number: number,
            url: "https://github.com/example-org/app/pull/\(number)", title: "Change \(number)",
            headRef: "feature-\(number)", headOid: String(repeating: "b", count: 40), baseRef: "main",
            items: items.map { PRSnapshotItem(githubNodeId: "\(number)-\($0)", kind: .thread, author: "reviewer", body: $0) }
        ))
    }

    private func triager(on watch: PRWatch) throws -> TokenIdentity {
        let task = try f.board.createTriageTask(
            watchId: watch.id, baseOid: String(repeating: "a", count: 40), headOid: watch.headOid
        )
        let sessionId = "triager-\(watch.number)"
        try f.board.assign(
            taskId: task.id,
            session: AgentSession(
                sessionId: sessionId, projectId: f.project.id, taskId: task.id, role: .worker,
                worktreePath: "/wt/\(task.id)", cwd: "/wt/\(task.id)", state: .running
            )
        )
        return f.triagerIdentity(sessionId: sessionId, taskId: task.id)
    }

    private func itemIds(_ watch: PRWatch) throws -> [Int64] {
        try watches.items(watchId: watch.id).compactMap(\.id)
    }

    private func verdict(_ id: Int64, _ verdict: String, extra: [String: JSONValue] = [:]) -> JSONValue {
        .object(["item_id": .number(Double(id)), "verdict": .string(verdict), "approach": .string("because")]
            .merging(extra) { $1 })
    }

    func testATriagerHasOnlyItsThreeToolsAndCannotCallAnOrchestratorTool() async throws {
        let identity = try triager(on: try watch(1, items: ["rename this"]))
        let names = Set(await f.scoped.tools(for: identity).map(\.name))
        XCTAssertEqual(names, ["get_pr_items", "set_verdicts", "log_progress"])

        let other = try f.task("unrelated", column: .ready)
        await XCTAssertThrowsErrorAsync(
            try await self.f.call("spawn_worker", ["task_id": .string(other.id)], as: identity)
        )
        let spawned = await f.control.spawned
        XCTAssertTrue(spawned.isEmpty)
    }

    func testSetVerdictsOnAnotherWatchsItemIsRefusedAndWritesNothing() async throws {
        let mine = try watch(1, items: ["rename this"])
        let theirs = try watch(2, items: ["add a test"])
        let identity = try triager(on: mine)
        let own = try XCTUnwrap(itemIds(mine).first)
        let foreign = try XCTUnwrap(itemIds(theirs).first)

        await XCTAssertToolError(
            try await self.f.call(
                "set_verdicts", ["verdicts": .array([verdict(own, "fix"), verdict(foreign, "fix")])], as: identity
            ),
            containing: "not one of this pull request's items"
        )
        XCTAssertEqual(try watches.items(watchId: mine.id).map(\.verdict), [nil])
        XCTAssertEqual(try watches.items(watchId: theirs.id).map(\.verdict), [nil])
    }

    func testVerdictsPersistAndTheLastOneFinishesTheTriage() async throws {
        let pr = try watch(1, items: ["rename this", "pick a cache size"])
        let identity = try triager(on: pr)
        let ids = try itemIds(pr)

        let first = try await f.call("set_verdicts", ["verdicts": .array([verdict(ids[0], "fix")])], as: identity)
        XCTAssertTrue(first.text.contains("Still without a verdict: \(ids[1])"), first.text)
        XCTAssertEqual(try f.tasks.get(try XCTUnwrap(identity.taskId))?.column, .running)

        _ = try await f.call(
            "set_verdicts",
            ["verdicts": .array([verdict(ids[1], "decision", extra: [
                "decision_question": .string("How large should the cache be?"),
                "decision_options": .array([.string("64 entries"), .string("Unbounded")]),
            ])])],
            as: identity
        )
        let items = try watches.items(watchId: pr.id)
        XCTAssertEqual(items.map(\.verdict), [.fix, .decision])
        XCTAssertEqual(items.map(\.approach), ["because", "because"])
        XCTAssertEqual(items[1].decisionQuestion, "How large should the cache be?")
        XCTAssertEqual(items[1].decisionOptionsJSON, #"["64 entries","Unbounded"]"#)
        XCTAssertEqual(try f.tasks.get(try XCTUnwrap(identity.taskId))?.column, .done)
        XCTAssertEqual(try f.sessions.get("triager-1")?.state, .completed)
        let events = await f.events.events
        XCTAssertTrue(events.contains(.workerCompleted(projectId: f.project.id, sessionId: "triager-1")))
    }

    func testTheGuardDeniesATriagerFileEditsGitWritesAndGh() async throws {
        let identity = try triager(on: try watch(1, items: ["rename this"]))
        let sessionId = try XCTUnwrap(identity.sessionId)
        for command in ["git commit -am fix", "git -C /wt fetch origin", "gh pr view 1", "/usr/bin/gh api user"] {
            let decision = await f.preToolUse(command, sessionId: sessionId, identity: identity)
            XCTAssertEqual(decision?.permissionDecision, "deny", command)
        }
        let edit = await f.preToolUseWrite("/wt/Sources/App.swift", sessionId: sessionId, identity: identity)
        XCTAssertEqual(edit?.permissionDecision, "deny")

        let diff = await f.preToolUse(
            "git diff \(String(repeating: "a", count: 40))...HEAD && git log --oneline", sessionId: sessionId,
            identity: identity
        )
        XCTAssertNotEqual(diff?.permissionDecision, "deny")
    }
}
