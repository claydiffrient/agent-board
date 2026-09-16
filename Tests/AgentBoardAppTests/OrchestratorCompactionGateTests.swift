import AgentBoardCore
import XCTest
@testable import AgentBoard

/// Compaction is bytes in the same PTY the human types into and it starts a turn of its own, so it
/// goes through the same gate as the report notice (SPEC §9.2). These cover the two ways it can go
/// wrong — landing on a half-typed message, and landing mid-dispatch — and the case where a
/// compaction and a report notice are both waiting.
@MainActor
final class OrchestratorCompactionGateTests: XCTestCase {
    @MainActor
    private final class Harness {
        var running = true
        var promptIsDirty = false
        var pending: ReportNoticeGate.Pending? = (count: 1, maxId: 1)
        private(set) var notices: [Int] = []
        private(set) var compactions = 0
        private(set) var reorientations = 0
        /// Injection order across both kinds, which is what the PTY actually sees.
        private(set) var written: [String] = []

        lazy var gate = ReportNoticeGate(
            isRunning: { [unowned self] in self.running },
            promptIsDirty: { [unowned self] in self.promptIsDirty },
            pendingReports: { [unowned self] in self.pending },
            deliver: { [unowned self] count in
                self.notices.append(count)
                self.written.append("notice")
            },
            deliverCompaction: { [unowned self] in
                self.compactions += 1
                self.written.append("compact")
            },
            deliverReorientation: { [unowned self] in
                self.reorientations += 1
                self.written.append("reorient")
            }
        )

        func submit() {
            promptIsDirty = false
            gate.promptCleared(submitted: true)
        }

        func cancel() {
            promptIsDirty = false
            gate.promptCleared(submitted: false)
        }
    }

    /// The gate starts with no turn behind it, so an immediate compaction would be mid-turn.
    private func idleHarness() -> Harness {
        let harness = Harness()
        harness.pending = nil
        harness.gate.turnEnded()
        return harness
    }

    // MARK: - Never onto a half-typed message

    func testCompactionIsWithheldWhileThePromptIsDirty() {
        let harness = idleHarness()
        harness.promptIsDirty = true

        harness.gate.compactionNeeded()

        XCTAssertEqual(harness.compactions, 0, "/compact was typed on top of the human's unsubmitted text")
        XCTAssertTrue(harness.gate.heldRequests.contains(.compact), "it was dropped rather than held")
    }

    func testAWithheldCompactionGoesOutWhenTheHumanCancels() {
        let harness = idleHarness()
        harness.promptIsDirty = true
        harness.gate.compactionNeeded()

        harness.cancel()

        XCTAssertEqual(harness.compactions, 1)
        XCTAssertTrue(harness.gate.heldRequests.isEmpty)
    }

    /// A submit starts a turn, so the held compaction has to wait one more beat rather than landing
    /// behind the message the human just sent.
    func testAWithheldCompactionWaitsForTheTurnTheHumansSubmitStarted() {
        let harness = idleHarness()
        harness.promptIsDirty = true
        harness.gate.compactionNeeded()

        harness.submit()
        XCTAssertEqual(harness.compactions, 0, "/compact landed on top of the turn the human just started")

        harness.gate.turnEnded()
        XCTAssertEqual(harness.compactions, 1)
    }

    // MARK: - Never mid-turn

    func testCompactionIsWithheldMidTurnAndDeliveredAfterTurnEnded() {
        let harness = Harness()
        harness.pending = nil

        harness.gate.compactionNeeded()
        XCTAssertEqual(harness.compactions, 0, "compacted a session that had not finished a turn")

        harness.gate.turnEnded()
        XCTAssertEqual(harness.compactions, 1)
    }

    func testTheTickAskingRepeatedlyStillCompactsOnlyOnce() {
        let harness = idleHarness()

        harness.gate.compactionNeeded()
        harness.gate.compactionNeeded()
        harness.gate.compactionNeeded()

        XCTAssertEqual(harness.compactions, 1)
    }

    /// The transcript keeps reading over threshold until the compacted one is written, so the tick
    /// asks again while the compaction is still running.
    func testAskingAgainWhileACompactionIsInFlightIsIgnored() {
        let harness = idleHarness()
        harness.gate.compactionNeeded()
        XCTAssertTrue(harness.gate.compactionInFlight)

        harness.gate.turnEnded()
        harness.gate.compactionNeeded()

        XCTAssertEqual(harness.compactions, 1)
    }

    // MARK: - A held compaction and a held notice both survive

    func testAHeldCompactionAndAHeldReportNoticeBothSurvive() {
        let harness = idleHarness()
        harness.promptIsDirty = true
        harness.pending = (count: 3, maxId: 9)

        harness.gate.reportsChanged()
        harness.gate.compactionNeeded()
        XCTAssertEqual(harness.gate.heldRequests, [.compact, .announce])

        // One line per pass: the compaction goes first, and the notice waits out the turn it began.
        harness.cancel()
        XCTAssertEqual(harness.written, ["compact"])
        XCTAssertEqual(harness.gate.heldRequests, [.announce], "the compaction dropped the report notice")

        harness.gate.turnEnded()
        XCTAssertEqual(harness.written, ["compact", "notice"])
        XCTAssertEqual(harness.notices, [3])
        XCTAssertTrue(harness.gate.heldRequests.isEmpty)
    }

    /// The other order: a notice already went out, the compaction is what has to wait.
    func testACompactionHeldBehindANoticeIsNotDropped() {
        let harness = Harness()
        harness.pending = (count: 2, maxId: 5)
        harness.gate.turnEnded()
        XCTAssertEqual(harness.written, ["notice"])

        harness.gate.compactionNeeded()
        XCTAssertEqual(harness.written, ["notice"], "compacted while the notice's turn was still running")
        XCTAssertEqual(harness.gate.heldRequests, [.compact])

        harness.gate.turnEnded()
        XCTAssertEqual(harness.written, ["notice", "compact"])
    }

    func testAHeldNoticeDoesNotDropAHeldCompaction() {
        let harness = idleHarness()
        harness.promptIsDirty = true
        harness.gate.compactionNeeded()
        harness.pending = (count: 1, maxId: 4)
        harness.gate.reportsChanged()
        harness.gate.nudge()

        XCTAssertEqual(harness.gate.heldRequests, [.compact, .nudge], "the notice replaced the compaction")
    }

    func testANudgeStillOutranksAnAnnounceAmongNotices() {
        let harness = idleHarness()
        harness.promptIsDirty = true
        harness.pending = (count: 1, maxId: 1)
        harness.gate.reportsChanged()
        harness.gate.nudge()

        XCTAssertEqual(harness.gate.heldRequests, [.nudge])
    }

    // MARK: - Re-orientation after the compaction lands

    func testAManualCompactionIsFollowedByTheReorientationLine() {
        let harness = idleHarness()
        harness.gate.compactionNeeded()

        harness.gate.compactionFinished(wasOurs: true)

        XCTAssertEqual(harness.reorientations, 1)
        XCTAssertEqual(harness.written, ["compact", "reorient"])
        XCTAssertFalse(harness.gate.compactionInFlight)
    }

    /// Claude Code's own auto-compaction resumes the turn by itself (measured, SPEC §2); writing a
    /// line into it would land mid-turn.
    func testAnAutoCompactionGetsNoReorientationLine() {
        let harness = idleHarness()

        harness.gate.compactionFinished(wasOurs: false)

        XCTAssertEqual(harness.reorientations, 0)
        XCTAssertTrue(harness.gate.heldRequests.isEmpty)
    }

    func testTheReorientationIsWithheldWhileThePromptIsDirty() {
        let harness = idleHarness()
        harness.gate.compactionNeeded()
        harness.promptIsDirty = true

        harness.gate.compactionFinished(wasOurs: true)
        XCTAssertEqual(harness.reorientations, 0)

        harness.cancel()
        XCTAssertEqual(harness.reorientations, 1)
    }

    func testARestartForgetsEverythingHeld() {
        let harness = idleHarness()
        harness.promptIsDirty = true
        harness.gate.compactionNeeded()

        harness.gate.processRestarted()
        harness.promptIsDirty = false
        harness.gate.promptCleared(submitted: false)

        XCTAssertEqual(harness.compactions, 0, "a compaction held for the dead child was typed into the new one")
        XCTAssertFalse(harness.gate.compactionInFlight)
    }

    func testNothingIsCompactedWhenTheProcessIsNotRunning() {
        let harness = idleHarness()
        harness.running = false

        harness.gate.compactionNeeded()

        XCTAssertEqual(harness.compactions, 0)
    }
}
