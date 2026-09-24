import AgentBoardCore
import XCTest
@testable import AgentBoard

final class StatusSearchTests: XCTestCase {
    private func session(
        shortId: String = "s-idle01", state: SessionState = .running, model: String? = nil, lastTool: String? = nil
    ) -> AgentSession {
        AgentSession(
            sessionId: "9f3c2a71-0000-4000-8000-000000000000", shortId: shortId, projectId: "p", role: .worker,
            cwd: "/tmp", state: state, model: model, lastTool: lastTool
        )
    }

    private func matches(_ text: String, _ session: AgentSession, title: String? = "Idle cap watchdog",
                         role: String = "worker") -> Bool {
        SearchQuery(text).matches(StatusSearch.fields(of: session, taskTitle: title, roleLabel: role))
    }

    private func port(
        _ number: Int = 3000, command: String = "node", sessionId: String? = "s-1",
        taskTitle: String? = "Idle cap watchdog", projectName: String = "derivita-ui"
    ) -> AttributedPort {
        AttributedPort(
            port: number, pid: 501, command: command, ownership: sessionId == nil ? .shellConsole : .orphaned,
            sessionId: sessionId, projectId: "p", projectName: projectName, taskTitle: taskTitle
        )
    }

    private func matches(_ text: String, _ port: AttributedPort) -> Bool {
        SearchQuery(text).matches(StatusSearch.fields(of: port))
    }

    func testASessionMatchesOnEveryFieldItsRowCarries() {
        let row = session(state: .setup, model: "claude-opus-5-5")
        XCTAssertTrue(matches("idle cap", row), "task title")
        XCTAssertTrue(matches("s-idle", row), "short id")
        XCTAssertTrue(matches("rita", row, role: "reviewer · Rita"), "rostered agent")
        XCTAssertTrue(matches("reviewer", row, role: "reviewer · Rita"), "role")
        XCTAssertTrue(matches("setting up", row), "state as drawn")
        XCTAssertTrue(matches("setup", row), "state as stored")
        XCTAssertTrue(matches("opus 5.5", row), "model name")
        XCTAssertTrue(matches("claude-opus", row), "model id")
        XCTAssertFalse(matches("port sweep", row))
    }

    func testEveryTermMustBeInTheSameSession() {
        XCTAssertTrue(matches("idle running", session()))
        XCTAssertFalse(matches("idle failed", session()))
    }

    func testASessionDoesNotMatchOnItsLastToolOrItsFullId() {
        let row = session(lastTool: "Bash")
        XCTAssertFalse(matches("bash", row))
        XCTAssertFalse(matches("9f3c2a71", row))
    }

    func testAPortMatchesOnItsNumberCommandAndOwner() {
        XCTAssertTrue(matches(":3000", port()))
        XCTAssertTrue(matches("3000", port()))
        XCTAssertTrue(matches("node", port()))
        XCTAssertTrue(matches("idle cap", port()), "the owning session's task")
        XCTAssertTrue(matches("terminal", port(sessionId: nil, taskTitle: nil)), "a shell console's port")
        XCTAssertTrue(matches("session s-1", port(taskTitle: nil)), "a session with no task")
        XCTAssertFalse(matches(":5173", port()))
    }

    func testAPortDoesNotMatchOnTheProjectNameEveryPortOnThePaneShares() {
        XCTAssertFalse(matches("derivita", port()))
    }

    func testAPortQueryDoesNotMatchASession() {
        XCTAssertFalse(matches(":3000", session()))
    }

    func testTheNoteCountsPortsAndHiddenEndedMatches() {
        XCTAssertNil(StatusSearch.note(hiddenEndedMatches: 0, shownPorts: 0, totalPorts: 0))
        XCTAssertEqual(StatusSearch.note(hiddenEndedMatches: 0, shownPorts: 1, totalPorts: 2), "1 of 2 ports")
        XCTAssertEqual(StatusSearch.note(hiddenEndedMatches: 0, shownPorts: 1, totalPorts: 1), "1 of 1 port")
        XCTAssertEqual(StatusSearch.note(hiddenEndedMatches: 0, shownPorts: 0, totalPorts: 2), "no ports match")
        XCTAssertEqual(StatusSearch.note(hiddenEndedMatches: 1, shownPorts: 0, totalPorts: 0), "1 ended match hidden")
        XCTAssertEqual(
            StatusSearch.note(hiddenEndedMatches: 3, shownPorts: 2, totalPorts: 4),
            "3 ended matches hidden · 2 of 4 ports"
        )
    }

    func testTheSummaryReadsAcrossBothSections() {
        XCTAssertEqual(SearchNoun.sessions.prompt, "Search sessions and ports")
        XCTAssertEqual(
            SearchSummary.text(
                query: ":3000", shown: 0, total: 5, noun: .sessions,
                note: StatusSearch.note(hiddenEndedMatches: 0, shownPorts: 1, totalPorts: 2)
            ),
            "No sessions match “:3000” · 1 of 2 ports"
        )
    }
}
