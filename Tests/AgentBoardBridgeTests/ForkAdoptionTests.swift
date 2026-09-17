import AgentBoardBridge
import AgentBoardCore
import AgentBoardServer
import Foundation
import XCTest

/// SPEC §2: `/clear` emits `SessionEnd` for the old id, then `SessionStart` with `source: "fork"`
/// under a new id that names no parent. The token grant is the only link back.
final class ForkAdoptionTests: XCTestCase {
    private var f: BridgeFixture!
    private var grants: TokenGrantStore!
    private var resolver: StoreTokenResolver!

    override func setUpWithError() throws {
        f = try BridgeFixture.make()
        grants = TokenGrantStore(f.db)
        resolver = StoreTokenResolver(db: f.db)
    }

    private func identity(scope: AgentBoardCore.TokenScope, boundTo sessionId: String?, taskId: String? = nil) async throws -> TokenIdentity {
        let grant = try grants.issue(projectId: f.project.id, scope: scope, taskId: taskId)
        if let sessionId {
            try grants.bind(token: grant.token, sessionId: sessionId)
        }
        let resolved = await resolver.resolve(token: grant.token)
        return try XCTUnwrap(resolved)
    }

    func testOrchestratorForkAdoptsTheNewSessionIdAndRepinsTheProject() async throws {
        try f.session("3ecc45ba", role: .orchestrator, state: .stopped)
        try f.sessions.updateSpend("3ecc45ba", tokensIn: 4_000, tokensOut: 900, cacheRead: 12, cacheWrite: 7, estCostUSD: 1.25, model: "claude-opus-5")
        try f.projects.setOrchestratorSession(f.project.id, sessionId: "3ecc45ba")
        let identity = try await identity(scope: .orchestrator, boundTo: "3ecc45ba")

        let event = HookEvent(name: "SessionStart", sessionId: "40cccc09", transcriptPath: "/tmp/40cccc09.jsonl", rawJSON: "{\"source\":\"fork\"}")
        _ = await f.hooks.handle(event, identity: identity)

        let adopted = try XCTUnwrap(f.sessions.get("40cccc09"))
        XCTAssertEqual(adopted.state, .running)
        XCTAssertEqual(adopted.role, .orchestrator)
        XCTAssertEqual(adopted.projectId, f.project.id)
        XCTAssertEqual(adopted.cwd, "/tmp")
        XCTAssertEqual(adopted.transcriptPath, "/tmp/40cccc09.jsonl")
        XCTAssertEqual(adopted.estCostUSD, 0)

        XCTAssertEqual(try grants.resolve(token: identity.token)?.sessionId, "40cccc09")
        XCTAssertEqual(try f.projects.get(f.project.id)?.orchSessionId, "40cccc09")

        let prior = try XCTUnwrap(f.sessions.get("3ecc45ba"))
        XCTAssertEqual(prior.state, .stopped)
        XCTAssertEqual(prior.tokensIn, 4_000)
        XCTAssertEqual(prior.estCostUSD, 1.25, accuracy: 0.0001)
    }

    func testWorkerForkKeepsTheTaskBindingAndLeavesTheProjectPinAlone() async throws {
        let task = try f.task("Add the sidebar", column: .running)
        try f.session("w1", taskId: task.id)
        try f.sessions.setShortId("w1", "abcd1234")
        try f.session("orch-1", role: .orchestrator, state: .running)
        try f.projects.setOrchestratorSession(f.project.id, sessionId: "orch-1")
        let identity = try await identity(scope: .worker, boundTo: "w1", taskId: task.id)

        let event = HookEvent(name: "PostToolUse", sessionId: "w2", toolName: "Bash", rawJSON: "{}")
        _ = await f.hooks.handle(event, identity: identity)

        let adopted = try XCTUnwrap(f.sessions.get("w2"))
        XCTAssertEqual(adopted.state, .running)
        XCTAssertEqual(adopted.role, .worker)
        XCTAssertEqual(adopted.taskId, task.id)
        XCTAssertEqual(adopted.shortId, "abcd1234")
        XCTAssertEqual(adopted.lastTool, "Bash")

        XCTAssertEqual(try grants.resolve(token: identity.token)?.sessionId, "w2")
        XCTAssertEqual(try f.projects.get(f.project.id)?.orchSessionId, "orch-1")
    }

    func testUnknownSessionWithNoLiveGrantIsStillIgnored() async throws {
        let identity = try await identity(scope: .worker, boundTo: String?.none)

        _ = await f.hooks.handle(HookEvent(name: "SessionStart", sessionId: "ghost", rawJSON: "{}"), identity: identity)

        XCTAssertNil(try f.sessions.get("ghost"))
    }

    func testForkIsNotAdoptedAcrossProjects() async throws {
        let other = try f.otherProject()
        try f.sessions.insert(AgentSession(sessionId: "other-orch", projectId: other.id, role: .orchestrator, cwd: "/tmp/other", state: .stopped))
        let identity = try await identity(scope: .orchestrator, boundTo: "other-orch")

        _ = await f.hooks.handle(HookEvent(name: "SessionStart", sessionId: "fork-1", rawJSON: "{}"), identity: identity)

        XCTAssertNil(try f.sessions.get("fork-1"))
        XCTAssertNil(try f.projects.get(f.project.id)?.orchSessionId)
    }

    func testWorkerGrantDoesNotAdoptAnOrchestratorSession() async throws {
        try f.session("orch-1", role: .orchestrator, state: .stopped)
        let identity = try await identity(scope: .worker, boundTo: "orch-1")

        _ = await f.hooks.handle(HookEvent(name: "SessionStart", sessionId: "fork-1", rawJSON: "{}"), identity: identity)

        XCTAssertNil(try f.sessions.get("fork-1"))
    }

    func testAKnownSessionIdIsNotTreatedAsAFork() async throws {
        try f.session("orch-1", role: .orchestrator, state: .stopped)
        try f.session("orch-2", role: .orchestrator, state: .stopped)
        try f.projects.setOrchestratorSession(f.project.id, sessionId: "orch-1")
        let identity = try await identity(scope: .orchestrator, boundTo: "orch-1")

        _ = await f.hooks.handle(HookEvent(name: "SessionStart", sessionId: "orch-2", rawJSON: "{}"), identity: identity)

        XCTAssertEqual(try grants.resolve(token: identity.token)?.sessionId, "orch-1")
        XCTAssertEqual(try f.projects.get(f.project.id)?.orchSessionId, "orch-1")
    }
}
