import Foundation
import XCTest
@testable import AgentBoardCore

final class SessionStoreTests: XCTestCase {
    func testActiveFiltersByStateAndProject() throws {
        let f = try Fixture.make()
        let other = try f.projects.register(name: "Other", repoPath: "/other", baseBranch: "main", worktreeRoot: "/w", memoryDir: nil)
        for state in SessionState.allCases {
            try f.sessions.insert(f.session("s-\(state.rawValue)", state: state))
        }
        try f.sessions.insert(AgentSession(sessionId: "elsewhere", projectId: other.id, role: .worker, cwd: "/", state: .running))

        let active = try f.sessions.active(projectId: f.project.id)
        XCTAssertEqual(Set(active.map(\.state)), [.setup, .starting, .running, .idle, .blocked])
        XCTAssertFalse(active.contains { $0.sessionId == "elsewhere" })
        XCTAssertEqual(try f.sessions.all(projectId: f.project.id).count, SessionState.allCases.count)
    }

    func testMutators() throws {
        let f = try Fixture.make()
        try f.sessions.insert(f.session("s1", state: .starting))

        try f.sessions.setState("s1", .running)
        XCTAssertEqual(try f.sessions.get("s1")?.state, .running)
        XCTAssertNil(try f.sessions.get("s1")?.endedAt)

        try f.sessions.recordActivity("s1", at: 1234, lastTool: "Bash")
        try f.sessions.recordActivity("s1", at: 2345, lastTool: nil)
        var s = try XCTUnwrap(f.sessions.get("s1"))
        XCTAssertEqual(s.lastActivity, 2345)
        XCTAssertEqual(s.lastTool, "Bash")

        try f.sessions.updateSpend("s1", tokensIn: 10, tokensOut: 20, cacheRead: 30, cacheWrite: 40, estCostUSD: 0.5, model: "claude-x")
        try f.sessions.updateSpend("s1", tokensIn: 11, tokensOut: 21, cacheRead: 31, cacheWrite: 41, estCostUSD: 0.6, model: nil)
        s = try XCTUnwrap(f.sessions.get("s1"))
        XCTAssertEqual(s.tokensIn, 11)
        XCTAssertEqual(s.tokensOut, 21)
        XCTAssertEqual(s.cacheRead, 31)
        XCTAssertEqual(s.cacheWrite, 41)
        XCTAssertEqual(s.estCostUSD, 0.6)
        XCTAssertEqual(s.model, "claude-x")
        XCTAssertEqual(s.totalTokens, 104)

        try f.sessions.setTranscriptPath("s1", "/t.jsonl")
        try f.sessions.setShortId("s1", "abcd1234")
        try f.sessions.setStopReason("s1", "cap")
        try f.sessions.setState("s1", .stopped, endedAt: 9999)
        s = try XCTUnwrap(f.sessions.get("s1"))
        XCTAssertEqual(s.transcriptPath, "/t.jsonl")
        XCTAssertEqual(s.shortId, "abcd1234")
        XCTAssertEqual(s.stopReason, "cap")
        XCTAssertEqual(s.state, .stopped)
        XCTAssertEqual(s.endedAt, 9999)
    }

    func testSessionStateIsActive() {
        XCTAssertEqual(SessionState.allCases.filter(\.isActive), [.setup, .starting, .running, .idle, .blocked])
    }
}

final class TokenGrantStoreTests: XCTestCase {
    func testIssueBindResolveRevoke() throws {
        let f = try Fixture.make()
        let t = try f.task("t")
        let grant = try f.tokens.issue(projectId: f.project.id, scope: .worker, taskId: t.id)
        XCTAssertEqual(grant.token.count, 32)
        XCTAssertTrue(grant.token.allSatisfy { $0.isHexDigit })
        XCTAssertNil(grant.sessionId)
        XCTAssertEqual(grant.scope, .worker)
        XCTAssertEqual(grant.taskId, t.id)

        XCTAssertEqual(try f.tokens.resolve(token: grant.token), grant)

        try f.sessions.insert(f.session("s1", taskId: t.id))
        try f.tokens.bind(token: grant.token, sessionId: "s1")
        let bound = try XCTUnwrap(f.tokens.resolve(token: grant.token))
        XCTAssertEqual(bound.sessionId, "s1")
        XCTAssertEqual(try f.tokens.forSession("s1").map(\.token), [grant.token])

        try f.tokens.revoke(token: grant.token)
        XCTAssertNil(try f.tokens.resolve(token: grant.token))
        XCTAssertNil(try f.tokens.resolve(token: "unknown"))
    }

    func testRevokeAllForSessionLeavesOtherSessionsAlone() throws {
        let f = try Fixture.make()
        try f.sessions.insert(f.session("s1"))
        try f.sessions.insert(f.session("s2"))
        let a = try f.tokens.issue(projectId: f.project.id, scope: .worker, taskId: nil)
        let b = try f.tokens.issue(projectId: f.project.id, scope: .orchestrator, taskId: nil)
        try f.tokens.bind(token: a.token, sessionId: "s1")
        try f.tokens.bind(token: b.token, sessionId: "s2")
        try f.tokens.revokeAll(sessionId: "s1")
        XCTAssertNil(try f.tokens.resolve(token: a.token))
        XCTAssertEqual(try f.tokens.resolve(token: b.token)?.scope, .orchestrator)
    }

    func testTokensAreUnique() throws {
        let f = try Fixture.make()
        var seen = Set<String>()
        for _ in 0..<50 {
            seen.insert(try f.tokens.issue(projectId: f.project.id, scope: .worker, taskId: nil).token)
        }
        XCTAssertEqual(seen.count, 50)
    }

    func testBindUnknownTokenThrows() throws {
        let f = try Fixture.make()
        try f.sessions.insert(f.session("s1"))
        XCTAssertThrowsError(try f.tokens.bind(token: "nope", sessionId: "s1")) { error in
            XCTAssertEqual(error as? BoardError, .tokenNotFound("nope"))
        }
    }
}
