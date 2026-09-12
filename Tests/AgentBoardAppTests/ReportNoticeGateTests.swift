import XCTest
@testable import AgentBoard

@MainActor
final class ReportNoticeGateTests: XCTestCase {
    /// Stands in for the PTY: the dirty flag the terminal view maintains, the unconsumed-report
    /// query, and the injection itself.
    @MainActor
    private final class Harness {
        var running = true
        var promptIsDirty = false
        var pending: ReportNoticeGate.Pending? = (count: 1, maxId: 1)
        private(set) var delivered: [Int] = []
        private(set) var pendingReads = 0

        lazy var gate = ReportNoticeGate(
            isRunning: { [unowned self] in self.running },
            promptIsDirty: { [unowned self] in self.promptIsDirty },
            pendingReports: { [unowned self] in
                self.pendingReads += 1
                return self.pending
            },
            deliver: { [unowned self] count in self.delivered.append(count) }
        )

        /// The prompt emptying — a submit or a cancel — as the terminal view reports it.
        func clearPrompt() {
            promptIsDirty = false
            gate.promptCleared()
        }
    }

    func testANoticeIsInjectedWhenThePromptIsClean() {
        let harness = Harness()
        harness.gate.turnEnded()
        XCTAssertEqual(harness.delivered, [1])
    }

    func testTurnEndedIsWithheldWhileThePromptIsDirty() {
        let harness = Harness()
        harness.promptIsDirty = true

        harness.gate.turnEnded()

        XCTAssertEqual(harness.delivered, [], "the notice was injected on top of the human's unsubmitted text")
    }

    func testReportsChangedIsWithheldWhileThePromptIsDirty() {
        let harness = Harness()
        harness.gate.turnEnded()
        harness.promptIsDirty = true
        harness.pending = (count: 2, maxId: 2)

        harness.gate.reportsChanged()

        XCTAssertEqual(harness.delivered, [1], "only the first, clean-prompt notice should have gone out")
    }

    func testNudgeIsWithheldWhileThePromptIsDirty() {
        let harness = Harness()
        harness.promptIsDirty = true

        harness.gate.nudge()

        XCTAssertEqual(harness.delivered, [])
    }

    func testAWithheldNoticeGoesOutWhenTheSubmitClearsThePrompt() {
        let harness = Harness()
        harness.promptIsDirty = true
        harness.gate.turnEnded()

        harness.clearPrompt()

        XCTAssertEqual(harness.delivered, [1])
    }

    func testAWithheldNudgeGoesOutWhenThePromptClears() {
        let harness = Harness()
        harness.promptIsDirty = true
        harness.gate.nudge()

        harness.clearPrompt()

        XCTAssertEqual(harness.delivered, [1])
    }

    func testTheCountIsReReadAtDeliveryRatherThanWhenItWasWithheld() {
        let harness = Harness()
        harness.promptIsDirty = true
        harness.gate.turnEnded()

        harness.pending = (count: 4, maxId: 7)
        harness.clearPrompt()

        XCTAssertEqual(harness.delivered, [4], "the stale count from the moment of deferral was sent")
        XCTAssertEqual(harness.gate.lastAnnouncedReportId, 7)
    }

    func testLastAnnouncedReportIdDoesNotAdvanceOnADeferral() {
        let harness = Harness()
        harness.promptIsDirty = true
        harness.pending = (count: 3, maxId: 9)

        harness.gate.turnEnded()

        XCTAssertEqual(harness.gate.lastAnnouncedReportId, 0, "deferred reports were marked announced and would be skipped")
    }

    func testDeferredReportsAreNotSkippedOnceThePromptClears() {
        let harness = Harness()
        harness.promptIsDirty = true
        harness.pending = (count: 3, maxId: 9)
        harness.gate.turnEnded()
        harness.gate.reportsChanged()

        harness.clearPrompt()

        XCTAssertEqual(harness.delivered, [3])
        XCTAssertEqual(harness.gate.lastAnnouncedReportId, 9)
    }

    func testAnAlreadyAnnouncedReportIsNotAnnouncedAgain() {
        let harness = Harness()
        harness.gate.turnEnded()
        harness.gate.turnEnded()
        XCTAssertEqual(harness.delivered, [1])
    }

    func testNudgeReAnnouncesWhatWasAlreadyAnnounced() {
        let harness = Harness()
        harness.gate.turnEnded()

        harness.gate.nudge()

        XCTAssertEqual(harness.delivered, [1, 1])
    }

    func testAWithheldNudgeStillReAnnouncesAfterThePromptClears() {
        let harness = Harness()
        harness.gate.turnEnded()
        harness.promptIsDirty = true
        harness.gate.nudge()

        harness.clearPrompt()

        XCTAssertEqual(harness.delivered, [1, 1])
    }

    func testReportsChangedBeforeAnyTurnEndsIsIgnored() {
        let harness = Harness()
        harness.gate.reportsChanged()
        XCTAssertEqual(harness.delivered, [])
    }

    func testNothingIsInjectedWhenTheProcessIsNotRunning() {
        let harness = Harness()
        harness.running = false
        harness.gate.turnEnded()
        harness.gate.nudge()
        XCTAssertEqual(harness.delivered, [])
    }

    func testNoNoticeWhenNothingIsPendingAtDeliveryTime() {
        let harness = Harness()
        harness.promptIsDirty = true
        harness.gate.turnEnded()

        harness.pending = (count: 0, maxId: 0)
        harness.clearPrompt()

        XCTAssertEqual(harness.delivered, [])
        XCTAssertEqual(harness.gate.lastAnnouncedReportId, 0)
    }

    func testAClearedPromptWithNothingHeldReadsNoReports() {
        let harness = Harness()
        harness.clearPrompt()
        XCTAssertEqual(harness.pendingReads, 0)
        XCTAssertEqual(harness.delivered, [])
    }
}
