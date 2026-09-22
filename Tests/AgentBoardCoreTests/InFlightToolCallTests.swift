import Foundation
import XCTest
@testable import AgentBoardCore

/// A tool call that has started but not returned is work. `PostToolUse` only fires when the tool
/// returns, so every deadline read off `last_activity` used to fire in the middle of a long
/// command — the stall indicator included.
final class InFlightToolCallTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 100_000)
    private func at(_ offset: TimeInterval) -> Date { now.addingTimeInterval(-offset) }
    private var awake: AwakeElapsed { AwakeElapsed(now: now) }

    func testTheGraceIsSixTimesWhateverDeadlineItExtends() {
        XCTAssertEqual(ToolCallGrace.deadline(extending: 300), 1800)
        XCTAssertEqual(ToolCallGrace.deadline(extending: 120), 720)
    }

    func testNoCallInFlightExcusesNothing() {
        XCTAssertFalse(ToolCallGrace.excusesSilence(toolStartedAt: nil, awake: awake, threshold: 120))
    }

    func testACallStillRunningExcusesSilencePastTheThreshold() {
        XCTAssertTrue(ToolCallGrace.excusesSilence(toolStartedAt: at(544), awake: awake, threshold: 120))
    }

    func testTheExcuseEndsExactlyAtTheGraceDeadline() {
        XCTAssertTrue(ToolCallGrace.excusesSilence(toolStartedAt: at(719), awake: awake, threshold: 120))
        XCTAssertFalse(ToolCallGrace.excusesSilence(toolStartedAt: at(720), awake: awake, threshold: 120))
    }

    /// The same clock as every other deadline here: a call that spanned a lid-close has not been
    /// running for the minutes the machine spent suspended.
    func testTheGraceIsMeasuredOnAwakeTimeOnly() {
        let slept = AwakeElapsed(
            now: now,
            sleeps: [ObservedSleep(endedAtMillis: Int64(now.timeIntervalSince1970 * 1000), millis: 600_000)]
        )
        XCTAssertTrue(ToolCallGrace.excusesSilence(toolStartedAt: at(1_000), awake: slept, threshold: 120))
    }

    // MARK: - The stall indicator reads the same signal

    private func stalled(silentFor silence: TimeInterval, toolStartedAt: Date?) -> Bool {
        AttentionSelection.isStalled(
            lastActivity: at(silence),
            startedAt: at(10_000),
            toolStartedAt: toolStartedAt,
            awake: awake,
            threshold: 120
        )
    }

    func testAWorkerInsideALongCommandIsNotReportedAsStuck() {
        XCTAssertFalse(stalled(silentFor: 544, toolStartedAt: at(544)))
    }

    func testAWorkerSilentWithNoCallInFlightIsStillReportedAsStuck() {
        XCTAssertTrue(stalled(silentFor: 544, toolStartedAt: nil))
    }

    /// The bound the stall indicator argues for is 6 × `stallSeconds`, which is 720s at the default
    /// — well inside the 1800s the idle cap allows the same call, so a wedged command still
    /// surfaces to the human before anything kills it.
    func testAWedgedCommandIsReportedAsStuckOnceItsGraceRunsOut() {
        XCTAssertTrue(stalled(silentFor: 900, toolStartedAt: at(900)))
    }

    /// In flight only ever *extends* the deadline. A `tool_started_at` left behind by a
    /// `PostToolUse` that never arrived can cost a worker its grace, never raise a false stall.
    func testAnInFlightCallNeverMakesAnActiveWorkerLookStalled() {
        XCTAssertFalse(stalled(silentFor: 5, toolStartedAt: at(10_000)))
    }
}
