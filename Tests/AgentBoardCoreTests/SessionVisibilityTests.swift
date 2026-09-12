import Foundation
import XCTest
@testable import AgentBoardCore

final class SessionVisibilityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let grace = SessionVisibility.endedGrace

    private static func millis(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

    private func session(
        _ id: String,
        state: SessionState,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        lastActivity: Date? = nil
    ) -> AgentSession {
        AgentSession(
            sessionId: id, projectId: "p", role: .worker, cwd: "/tmp", state: state,
            startedAt: Self.millis(startedAt ?? now.addingTimeInterval(-100_000)),
            endedAt: endedAt.map(Self.millis), lastActivity: lastActivity.map(Self.millis)
        )
    }

    private func ended(_ id: String, _ state: SessionState, ago: TimeInterval) -> AgentSession {
        session(id, state: state, endedAt: now.addingTimeInterval(-ago))
    }

    // MARK: - What counts as ended

    func testOnlyTerminalStatesAreEnded() {
        XCTAssertEqual(SessionState.allCases.filter(\.isEnded), [.stopped, .failed, .completed])
    }

    // MARK: - The grace-window boundary

    func testEndedJustInsideTheWindowStaysVisible() {
        let roster = SessionVisibility.roster([ended("s", .completed, ago: grace - 1)], now: now, grace: grace)
        XCTAssertEqual(roster.visible.map(\.sessionId), ["s"])
        XCTAssertEqual(roster.hiddenCount, 0)
    }

    func testEndedExactlyAtTheWindowEdgeIsHidden() {
        let roster = SessionVisibility.roster([ended("s", .completed, ago: grace)], now: now, grace: grace)
        XCTAssertTrue(roster.visible.isEmpty)
        XCTAssertEqual(roster.hiddenCount, 1)
    }

    func testEndedJustOutsideTheWindowIsHidden() {
        let roster = SessionVisibility.roster([ended("s", .completed, ago: grace + 1)], now: now, grace: grace)
        XCTAssertTrue(roster.visible.isEmpty)
        XCTAssertEqual(roster.hiddenCount, 1)
    }

    func testEveryTerminalStateObeysTheSameWindow() {
        for state in [SessionState.stopped, .failed, .completed] {
            XCTAssertEqual(
                SessionVisibility.roster([ended("s", state, ago: 90)], now: now, grace: grace).visible.count, 1,
                "\(state.rawValue) ended 90 seconds ago is what the human is looking for"
            )
            XCTAssertEqual(
                SessionVisibility.roster([ended("s", state, ago: grace * 2)], now: now, grace: grace).hiddenCount, 1,
                "\(state.rawValue) long ago belongs off the roster"
            )
        }
    }

    // MARK: - States that are never hidden

    func testIdleAndBlockedAreNeverHiddenAtAnyAge() {
        let ancient = now.addingTimeInterval(-grace * 1_000)
        for state in [SessionState.idle, .blocked] {
            let stale = session("s", state: state, startedAt: ancient, lastActivity: ancient)
            let roster = SessionVisibility.roster([stale], now: now, grace: grace)
            XCTAssertEqual(roster.visible.map(\.sessionId), ["s"], "\(state.rawValue) is resumable or wants a human")
            XCTAssertEqual(roster.hiddenCount, 0)
        }
    }

    func testRunningAndStartingAreNeverHidden() {
        let ancient = now.addingTimeInterval(-grace * 1_000)
        for state in [SessionState.running, .starting] {
            let long = session("s", state: state, startedAt: ancient, lastActivity: ancient)
            XCTAssertEqual(SessionVisibility.roster([long], now: now, grace: grace).visible.count, 1, state.rawValue)
        }
    }

    // MARK: - Mixed rosters

    func testHiddenCountAccountsForEveryDroppedRowAndOrderIsPreserved() {
        let sessions = [
            session("live", state: .running),
            ended("just-failed", .failed, ago: 90),
            ended("old-1", .completed, ago: grace * 3),
            session("idle", state: .idle, lastActivity: now.addingTimeInterval(-grace * 5)),
            ended("old-2", .stopped, ago: grace * 4),
            ended("old-3", .failed, ago: grace * 5),
        ]
        let roster = SessionVisibility.roster(sessions, now: now, grace: grace)

        XCTAssertEqual(roster.visible.map(\.sessionId), ["live", "just-failed", "idle"])
        XCTAssertEqual(roster.hiddenCount, 3)
        XCTAssertEqual(roster.visible.count + roster.hiddenCount, sessions.count, "nothing is dropped without being counted")
    }

    func testIncludeEndedReturnsTheWholeRosterAndHidesNothing() {
        let sessions = [session("live", state: .running), ended("old", .completed, ago: grace * 10)]
        let roster = SessionVisibility.roster(sessions, now: now, grace: grace, includeEnded: true)

        XCTAssertEqual(roster.visible.map(\.sessionId), ["live", "old"])
        XCTAssertEqual(roster.hiddenCount, 0)
    }

    func testDefaultGraceIsAnHour() {
        XCTAssertEqual(SessionVisibility.endedGrace, 3600)
        XCTAssertEqual(SessionVisibility.endedGraceDescription, "60 minutes")
    }

    // MARK: - When ended_at was never written

    func testSessionMarkedFailedWithoutAnEndTimeFallsBackToLastActivity() {
        let recent = session("s", state: .failed, startedAt: now.addingTimeInterval(-grace * 10), lastActivity: now.addingTimeInterval(-60))
        XCTAssertEqual(SessionVisibility.roster([recent], now: now, grace: grace).visible.count, 1)

        let stale = session("s", state: .failed, startedAt: now.addingTimeInterval(-grace * 10), lastActivity: now.addingTimeInterval(-grace * 2))
        XCTAssertEqual(SessionVisibility.roster([stale], now: now, grace: grace).hiddenCount, 1)
    }

    func testSessionWithNeitherEndNorActivityFallsBackToItsStart() {
        let young = session("s", state: .stopped, startedAt: now.addingTimeInterval(-60))
        XCTAssertEqual(SessionVisibility.roster([young], now: now, grace: grace).visible.count, 1)

        let old = session("s", state: .stopped, startedAt: now.addingTimeInterval(-grace * 2))
        XCTAssertEqual(SessionVisibility.roster([old], now: now, grace: grace).hiddenCount, 1)
    }

    func testEmptyRoster() {
        let roster = SessionVisibility.roster([], now: now, grace: grace)
        XCTAssertTrue(roster.visible.isEmpty)
        XCTAssertEqual(roster.hiddenCount, 0)
    }
}
