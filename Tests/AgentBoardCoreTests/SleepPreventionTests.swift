import XCTest
@testable import AgentBoardCore

final class SleepPreventionTests: XCTestCase {
    private func hold(_ states: [SessionState], enabled: Bool = true) -> Bool {
        SleepPrevention.shouldHold(enabled: enabled, states: states)
    }

    func testNoSessionsHoldsNothing() {
        XCTAssertFalse(hold([]))
    }

    func testEveryActiveStateOnItsOwnHolds() {
        for state in SessionState.activeStates {
            XCTAssertTrue(hold([state]), "\(state.rawValue) should hold the Mac awake")
        }
    }

    func testEveryEndedStateOnItsOwnHoldsNothing() {
        for state in SessionState.allCases where !state.isActive {
            XCTAssertFalse(hold([state]), "\(state.rawValue) should not hold the Mac awake")
        }
    }

    func testOneRunningAmongSeveralEndedStillHolds() {
        XCTAssertTrue(hold([.completed, .failed, .running, .stopped, .completed]))
        XCTAssertEqual(SleepPrevention.activeCount([.completed, .failed, .running, .stopped]), 1)
    }

    func testAllEndedHoldsNothing() {
        XCTAssertFalse(hold([.completed, .failed, .stopped]))
        XCTAssertEqual(SleepPrevention.activeCount([.completed, .failed, .stopped]), 0)
    }

    /// A worker that dies without reporting leaves its row active, so the assertion is still held —
    /// and the moment `reconcile` or the leaked-agent sweep flips the row it is released. The sweep
    /// itself is the seam: `LeakedAgentSweep.plan` decides purely from the same state.
    func testAStrandedSessionKeepsHoldingUntilTheSweepFlipsIt() {
        let stranded = AgentSession(
            sessionId: "s1", shortId: "abc", projectId: "p1", taskId: "t1", role: .worker,
            cwd: "/tmp", state: .running
        )
        XCTAssertTrue(hold([stranded.state]))
        XCTAssertEqual(LeakedAgentSweep.plan([stranded]).first?.outcome, .keep)

        let swept = AgentSession(
            sessionId: "s1", shortId: "abc", projectId: "p1", taskId: "t1", role: .worker,
            cwd: "/tmp", state: .failed
        )
        XCTAssertFalse(hold([swept.state]))
        XCTAssertEqual(LeakedAgentSweep.plan([swept]).first?.outcome, .stop)
    }

    func testTurningTheSettingOffHoldsNothingWhateverIsRunning() {
        for state in SessionState.allCases {
            XCTAssertFalse(hold([state], enabled: false))
        }
        XCTAssertFalse(hold([.running, .idle, .blocked], enabled: false))
    }

    func testTheAssertionNameIsWhatPmsetWillPrint() {
        XCTAssertEqual(SleepPrevention.assertionName, "Agent Board — an agent is running")
        XCTAssertTrue(SleepPrevention.assertionName.contains("Agent Board"))
    }

    func testTheFooterNeverImpliesLidCloseIsCovered() {
        let holding = SleepPrevention.footerHelp(enabled: true, activeCount: 2)
        XCTAssertTrue(holding.contains("Closing the lid"))
        XCTAssertTrue(holding.contains("idle system sleep only"))
        XCTAssertTrue(holding.contains("the display still sleeps"))
        XCTAssertTrue(holding.contains(SleepPrevention.assertionName))

        XCTAssertEqual(SleepPrevention.footerLabel(enabled: true, activeCount: 2), "Keeping this Mac awake — idle sleep only")
        XCTAssertEqual(SleepPrevention.footerLabel(enabled: true, activeCount: 0), "Mac may sleep — nothing running")
        XCTAssertEqual(SleepPrevention.footerLabel(enabled: false, activeCount: 2), "Sleep prevention off")
    }
}
