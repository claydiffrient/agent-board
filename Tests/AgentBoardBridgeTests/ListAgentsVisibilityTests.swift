import AgentBoardBridge
import AgentBoardCore
import AgentBoardServer
import Foundation
import XCTest

final class ListAgentsVisibilityTests: XCTestCase {
    private var f: BridgeFixture!

    override func setUpWithError() throws {
        f = try BridgeFixture.make()
    }

    @discardableResult
    private func endedSession(_ id: String, _ state: SessionState, secondsAgo: TimeInterval) throws -> AgentSession {
        let at = Int64.nowMillis - Int64(secondsAgo * 1000)
        let session = AgentSession(
            sessionId: id, projectId: f.project.id, role: .worker, cwd: "/tmp", state: state,
            startedAt: at - 60_000, endedAt: at, lastActivity: at
        )
        try f.sessions.insert(session)
        return session
    }

    private func listedIds(includeEnded: Bool? = nil) async throws -> [String] {
        var arguments: [String: JSONValue] = [:]
        if let includeEnded { arguments["include_ended"] = .bool(includeEnded) }
        let result = try await f.callJSON("list_agents", arguments)
        let rows = try XCTUnwrap(result.arrayValue)
        return rows.compactMap { $0["session_id"]?.stringValue }
    }

    func testDefaultHidesSessionsThatEndedBeforeTheGraceWindow() async throws {
        try f.session("live", state: .running)
        try endedSession("old-completed", .completed, secondsAgo: SessionVisibility.endedGrace * 2)
        try endedSession("old-failed", .failed, secondsAgo: SessionVisibility.endedGrace * 3)
        try endedSession("old-stopped", .stopped, secondsAgo: SessionVisibility.endedGrace * 4)

        let listed = try await listedIds()
        XCTAssertEqual(listed, ["live"])
    }

    func testDefaultKeepsSessionsThatEndedInsideTheGraceWindow() async throws {
        try endedSession("just-failed", .failed, secondsAgo: 90)

        let listed = try await listedIds()
        XCTAssertEqual(
            listed, ["just-failed"],
            "the orchestrator calls list_agents precisely because something just finished"
        )
    }

    func testDefaultKeepsIdleAndBlockedSessionsHoweverOldTheyAre() async throws {
        let ancient = Int64.nowMillis - Int64(SessionVisibility.endedGrace * 100 * 1000)
        for state in [SessionState.idle, .blocked] {
            try f.sessions.insert(
                AgentSession(
                    sessionId: "\(state.rawValue)-session", projectId: f.project.id, role: .worker, cwd: "/tmp",
                    state: state, startedAt: ancient, lastActivity: ancient
                )
            )
        }

        let listed = try await listedIds()
        XCTAssertEqual(Set(listed), ["idle-session", "blocked-session"])
    }

    func testIncludeEndedReturnsTheWholeRoster() async throws {
        try f.session("live", state: .running)
        try endedSession("old-completed", .completed, secondsAgo: SessionVisibility.endedGrace * 2)
        try endedSession("old-failed", .failed, secondsAgo: SessionVisibility.endedGrace * 3)

        let all = try await listedIds(includeEnded: true)
        let defaulted = try await listedIds(includeEnded: false)

        XCTAssertEqual(Set(all), ["live", "old-completed", "old-failed"])
        XCTAssertEqual(defaulted, ["live"])
    }

    func testHidingIsDisplayOnlyAndLeavesTheSessionRowIntact() async throws {
        try endedSession("old-completed", .completed, secondsAgo: SessionVisibility.endedGrace * 2)

        let listed = try await listedIds()

        XCTAssertTrue(listed.isEmpty)
        XCTAssertEqual(try f.sessions.get("old-completed")?.state, .completed)
        XCTAssertEqual(try f.sessions.all(projectId: f.project.id).count, 1)
    }

    func testToolDescriptionWarnsThatEndedSessionsAreHidden() async throws {
        let descriptors = await f.orchestrator.tools(for: f.orchestratorIdentity)
        let tool = try XCTUnwrap(descriptors.first { $0.name == "list_agents" })

        XCTAssertTrue(tool.description.contains("include_ended"), tool.description)
        XCTAssertTrue(
            tool.description.lowercased().contains("vanish"),
            "must tell the orchestrator a missing worker finished: \(tool.description)"
        )
        XCTAssertEqual(tool.inputSchema["properties"]?["include_ended"]?["type"], .string("boolean"))
    }
}
