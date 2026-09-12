import XCTest
@testable import AgentBoardRuntime

final class CapEvaluatorTests: XCTestCase {
    private let limits = CapLimits(maxTokens: 1000, maxWallClockSeconds: 600, maxIdleSeconds: 60)
    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testNoBreach() {
        let totals = UsageTotals(inputTokens: 400, outputTokens: 400, cacheReadTokens: 999_999, cacheWrite5mTokens: 100)
        let now = start.addingTimeInterval(300)
        XCTAssertNil(CapEvaluator.evaluate(totals: totals, startedAt: start, lastActivity: now.addingTimeInterval(-30), now: now, limits: limits))
    }

    func testCacheReadsAreNotCounted() {
        XCTAssertEqual(CapEvaluator.countedTokens(UsageTotals(inputTokens: 1, outputTokens: 2, cacheReadTokens: 1_000_000, cacheWrite5mTokens: 3, cacheWrite1hTokens: 4)), 3)
    }

    func testTokenBreach() {
        let totals = UsageTotals(inputTokens: 600, outputTokens: 400, cacheWrite1hTokens: 100_000)
        let breach = CapEvaluator.evaluate(totals: totals, startedAt: start, lastActivity: start, now: start.addingTimeInterval(1), limits: limits)
        XCTAssertEqual(breach, .tokens(used: 1000, limit: 1000))
    }

    func testNoTokenLimitNeverBreachesOnTokens() {
        let unlimited = CapLimits(maxTokens: nil, maxWallClockSeconds: 600, maxIdleSeconds: 60)
        let totals = UsageTotals(inputTokens: 5_000_000, outputTokens: 5_000_000)
        XCTAssertNil(CapEvaluator.evaluate(totals: totals, startedAt: start, lastActivity: start, now: start.addingTimeInterval(1), limits: unlimited))
    }

    func testTokenBreachTakesPrecedence() {
        let totals = UsageTotals(inputTokens: 5000)
        let now = start.addingTimeInterval(10_000)
        XCTAssertEqual(CapEvaluator.evaluate(totals: totals, startedAt: start, lastActivity: nil, now: now, limits: limits), .tokens(used: 5000, limit: 1000))
    }

    func testWallClockBreach() {
        let now = start.addingTimeInterval(600)
        let breach = CapEvaluator.evaluate(totals: .zero, startedAt: start, lastActivity: now, now: now, limits: limits)
        XCTAssertEqual(breach, .wallClock(elapsed: 600, limit: 600))
    }

    func testIdleBreach() {
        let last = start.addingTimeInterval(100)
        let now = last.addingTimeInterval(61)
        let breach = CapEvaluator.evaluate(totals: .zero, startedAt: start, lastActivity: last, now: now, limits: limits)
        XCTAssertEqual(breach, .idle(since: last, limit: 60))
    }

    func testIdleWithoutActivityMeasuresFromStart() {
        let now = start.addingTimeInterval(60)
        XCTAssertEqual(CapEvaluator.evaluate(totals: .zero, startedAt: start, lastActivity: nil, now: now, limits: limits), .idle(since: start, limit: 60))
        XCTAssertNil(CapEvaluator.evaluate(totals: .zero, startedAt: start, lastActivity: nil, now: start.addingTimeInterval(59), limits: limits))
    }

    func testDefaultsMatchSpec() {
        XCTAssertEqual(CapLimits.default, CapLimits(maxTokens: nil, maxWallClockSeconds: 1800, maxIdleSeconds: 300))
    }
}
