import AgentBoardCore
import XCTest
@testable import AgentBoardRuntime

final class CapEvaluatorTests: XCTestCase {
    private let limits = CapLimits(maxTokens: 1000, maxWallClockSeconds: 600, maxIdleSeconds: 60)
    private let start = Date(timeIntervalSince1970: 1_000_000)
    /// For the idle tests: an elapsed cap far enough out that only the idle cap can fire.
    private let idleOnly = CapLimits(maxTokens: 1000, maxWallClockSeconds: 86_400, maxIdleSeconds: 60)

    func testNoBreach() {
        let totals = UsageTotals(inputTokens: 400, outputTokens: 400, cacheReadTokens: 999_999, cacheWrite5mTokens: 100)
        let now = start.addingTimeInterval(300)
        XCTAssertNil(CapEvaluator.evaluate(totals: totals, startedAt: start, lastActivity: now.addingTimeInterval(-30), awake: .init(now: now), limits: limits))
    }

    func testCacheReadsAreNotCounted() {
        XCTAssertEqual(CapEvaluator.countedTokens(UsageTotals(inputTokens: 1, outputTokens: 2, cacheReadTokens: 1_000_000, cacheWrite5mTokens: 3, cacheWrite1hTokens: 4)), 3)
    }

    func testTokenBreach() {
        let totals = UsageTotals(inputTokens: 600, outputTokens: 400, cacheWrite1hTokens: 100_000)
        let breach = CapEvaluator.evaluate(totals: totals, startedAt: start, lastActivity: start, awake: .init(now: start.addingTimeInterval(1)), limits: limits)
        XCTAssertEqual(breach, .tokens(used: 1000, limit: 1000))
    }

    func testNoTokenLimitNeverBreachesOnTokens() {
        let unlimited = CapLimits(maxTokens: nil, maxWallClockSeconds: 600, maxIdleSeconds: 60)
        let totals = UsageTotals(inputTokens: 5_000_000, outputTokens: 5_000_000)
        XCTAssertNil(CapEvaluator.evaluate(totals: totals, startedAt: start, lastActivity: start, awake: .init(now: start.addingTimeInterval(1)), limits: unlimited))
    }

    func testTokenBreachTakesPrecedence() {
        let totals = UsageTotals(inputTokens: 5000)
        let now = start.addingTimeInterval(10_000)
        XCTAssertEqual(CapEvaluator.evaluate(totals: totals, startedAt: start, lastActivity: nil, awake: .init(now: now), limits: limits), .tokens(used: 5000, limit: 1000))
    }

    func testWallClockBreach() {
        let now = start.addingTimeInterval(600)
        let breach = CapEvaluator.evaluate(totals: .zero, startedAt: start, lastActivity: now, awake: .init(now: now), limits: limits)
        XCTAssertEqual(breach, .wallClock(elapsed: 600, limit: 600))
    }

    func testIdleBreach() {
        let last = start.addingTimeInterval(100)
        let now = last.addingTimeInterval(61)
        let breach = CapEvaluator.evaluate(totals: .zero, startedAt: start, lastActivity: last, awake: .init(now: now), limits: limits)
        XCTAssertEqual(breach, .idle(since: last, limit: 60))
    }

    func testIdleWithoutActivityMeasuresFromStart() {
        let now = start.addingTimeInterval(60)
        XCTAssertEqual(CapEvaluator.evaluate(totals: .zero, startedAt: start, lastActivity: nil, awake: .init(now: now), limits: limits), .idle(since: start, limit: 60))
        XCTAssertNil(CapEvaluator.evaluate(totals: .zero, startedAt: start, lastActivity: nil, awake: .init(now: start.addingTimeInterval(59)), limits: limits))
    }

    // MARK: - A suspended machine is not an idle worker

    /// The 2026-09-14 regression: the lid was closed for 20 minutes, the worker's activity clock
    /// had not moved because the process was suspended, and the 60s idle cap executed it on wake.
    func testALidClosedForTwentyMinutesDoesNotBreachTheIdleCap() {
        let last = start.addingTimeInterval(100)
        let now = last.addingTimeInterval(1205)
        let slept = ObservedSleep(endedAtMillis: Int64(now.timeIntervalSince1970 * 1000) - 5_000, millis: 1_200_000)

        XCTAssertEqual(
            CapEvaluator.evaluate(
                totals: .zero, startedAt: start, lastActivity: last, awake: .init(now: now), limits: idleOnly
            ),
            .idle(since: last, limit: 60),
            "same reading on the wall clock alone still reaps, which is the bug"
        )
        XCTAssertNil(
            CapEvaluator.evaluate(
                totals: .zero, startedAt: start, lastActivity: last,
                awake: .init(now: now, sleeps: [slept]), limits: idleOnly
            )
        )
    }

    /// The cap is not disabled by the fix: with the machine awake the whole time, the same 20
    /// minutes of silence is a breach.
    func testAGenuinelyIdleWorkerOnAnAwakeMachineStillBreaches() {
        let last = start.addingTimeInterval(100)
        let now = last.addingTimeInterval(1205)
        XCTAssertEqual(
            CapEvaluator.evaluate(
                totals: .zero, startedAt: start, lastActivity: last, awake: .init(now: now, sleeps: []),
                limits: idleOnly
            ),
            .idle(since: last, limit: 60)
        )
    }

    /// Sleep before the worker's last activity is nothing to do with this worker's silence.
    func testASleepThatEndedBeforeTheLastActivityStillLetsTheCapFire() {
        let last = start.addingTimeInterval(1000)
        let now = last.addingTimeInterval(61)
        let slept = ObservedSleep(endedAtMillis: Int64(last.timeIntervalSince1970 * 1000) - 1, millis: 900_000)
        XCTAssertEqual(
            CapEvaluator.evaluate(
                totals: .zero, startedAt: start, lastActivity: last,
                awake: .init(now: now, sleeps: [slept]), limits: idleOnly
            ),
            .idle(since: last, limit: 60)
        )
    }

    /// `maxWallClockSeconds` bounds how long an agent has been working, and a suspended process is
    /// not working, so it is measured on the same clock as the idle cap.
    func testTheElapsedCapAlsoExcludesSleep() {
        let now = start.addingTimeInterval(601)
        let slept = ObservedSleep(endedAtMillis: Int64(now.timeIntervalSince1970 * 1000), millis: 500_000)
        XCTAssertNil(
            CapEvaluator.evaluate(
                totals: .zero, startedAt: start, lastActivity: now, awake: .init(now: now, sleeps: [slept]),
                limits: limits
            )
        )
        XCTAssertEqual(
            CapEvaluator.evaluate(
                totals: .zero, startedAt: start, lastActivity: now, awake: .init(now: now), limits: limits
            ),
            .wallClock(elapsed: 601, limit: 600)
        )
    }

    /// Tokens are a count, not a duration: sleep cannot excuse them.
    func testTheTokenCapIsUnaffectedBySleep() {
        let now = start.addingTimeInterval(10)
        let slept = ObservedSleep(endedAtMillis: Int64(now.timeIntervalSince1970 * 1000), millis: 9_000)
        XCTAssertEqual(
            CapEvaluator.evaluate(
                totals: UsageTotals(inputTokens: 900, outputTokens: 200), startedAt: start, lastActivity: now,
                awake: .init(now: now, sleeps: [slept]), limits: limits
            ),
            .tokens(used: 1100, limit: 1000)
        )
    }

    /// A session waiting on another agent's file lock makes no tool call by design. Under the
    /// accounting this replaces — idle measured from `lastActivity` regardless of state — each of
    /// these returned `.idle` and the worker was killed holding exactly the work the lock protects.
    func testAWaitingSessionIsNotIdleButIsStillSubjectToTheOtherCaps() {
        let last = start.addingTimeInterval(100)
        let now = last.addingTimeInterval(61)
        XCTAssertEqual(
            CapEvaluator.evaluate(totals: .zero, startedAt: start, lastActivity: last, awake: .init(now: now), limits: limits),
            .idle(since: last, limit: 60),
            "a running session with the same clock must still breach"
        )
        for state in [SessionState.waitingOnLock, .blocked, .setup] {
            XCTAssertNil(
                CapEvaluator.evaluate(
                    totals: .zero, startedAt: start, lastActivity: last, awake: .init(now: now), limits: limits, state: state
                ),
                "\(state) was killed by the idle cap"
            )
        }

        let late = start.addingTimeInterval(600)
        XCTAssertEqual(
            CapEvaluator.evaluate(
                totals: .zero, startedAt: start, lastActivity: last, awake: .init(now: late), limits: limits,
                state: .waitingOnLock
            ),
            .wallClock(elapsed: 600, limit: 600),
            "the wall clock must still reach a waiting session"
        )
        XCTAssertEqual(
            CapEvaluator.evaluate(
                totals: UsageTotals(inputTokens: 500, outputTokens: 600, cacheReadTokens: 0, cacheWrite5mTokens: 0),
                startedAt: start, lastActivity: last, awake: .init(now: now), limits: limits, state: .waitingOnLock
            ),
            .tokens(used: 1100, limit: 1000),
            "the token cap must still reach a waiting session"
        )
    }

    // MARK: - A tool call in flight

    /// `PostToolUse` fires only when a tool returns, so a worker inside a 544s `swift build` had
    /// made no recorded activity for the whole of it and was reaped mid-command.
    func testACallStillRunningExcusesTheIdleCap() {
        let now = start.addingTimeInterval(300)
        XCTAssertNil(CapEvaluator.evaluate(
            totals: .zero, startedAt: start, lastActivity: start, toolStartedAt: start,
            awake: .init(now: now), limits: idleOnly
        ))
    }

    func testTheSameSilenceWithNoCallInFlightStillBreaches() {
        let now = start.addingTimeInterval(300)
        XCTAssertEqual(
            CapEvaluator.evaluate(
                totals: .zero, startedAt: start, lastActivity: start, awake: .init(now: now), limits: idleOnly
            ),
            .idle(since: start, limit: 60)
        )
    }

    /// The bound: 6× the idle cap, and not a second more.
    func testACallThatNeverReturnsBreachesAtSixTimesTheIdleCap() {
        XCTAssertNil(CapEvaluator.evaluate(
            totals: .zero, startedAt: start, lastActivity: start, toolStartedAt: start,
            awake: .init(now: start.addingTimeInterval(359)), limits: idleOnly
        ))
        XCTAssertEqual(
            CapEvaluator.evaluate(
                totals: .zero, startedAt: start, lastActivity: start, toolStartedAt: start,
                awake: .init(now: start.addingTimeInterval(360)), limits: idleOnly
            ),
            .idle(since: start, limit: 60)
        )
    }

    /// The grace extends a deadline, it never triggers one, so a `tool_started_at` left behind by a
    /// `PostToolUse` that never arrived cannot reap a worker that is plainly still working.
    func testAStaleStartCannotBreachAWorkerThatIsStillActive() {
        let now = start.addingTimeInterval(10_000)
        XCTAssertNil(CapEvaluator.evaluate(
            totals: .zero, startedAt: start, lastActivity: now.addingTimeInterval(-5),
            toolStartedAt: start, awake: .init(now: now), limits: idleOnly
        ))
    }

    /// The elapsed cap is not excused: nobody gets to sit inside one command forever.
    func testTheElapsedCapStillFiresThroughARunningCall() {
        let now = start.addingTimeInterval(600)
        XCTAssertEqual(
            CapEvaluator.evaluate(
                totals: .zero, startedAt: start, lastActivity: start, toolStartedAt: start,
                awake: .init(now: now), limits: limits
            ),
            .wallClock(elapsed: 600, limit: 600)
        )
    }

    func testDefaultsMatchSpec() {
        XCTAssertEqual(CapLimits.default, CapLimits(maxTokens: nil, maxWallClockSeconds: 1800, maxIdleSeconds: 300))
    }
}
