import XCTest
@testable import AgentBoardRuntime

final class PricingTests: XCTestCase {
    func testEstimateKnownTotal() {
        let totals = UsageTotals(inputTokens: 1_000_000, outputTokens: 100_000, cacheReadTokens: 2_000_000, cacheWrite5mTokens: 400_000, cacheWrite1hTokens: 100_000)
        let usd = PricingTable.default.estimateUSD(model: "claude-opus-5", totals: totals)
        // 5 + 2.5 + 1.0 + 2.5 + 1.0
        XCTAssertEqual(usd, 12.0, accuracy: 1e-9)
    }

    func testEstimateEachModelFamily() {
        let million = UsageTotals(inputTokens: 1_000_000)
        let table = PricingTable.default
        XCTAssertEqual(table.estimateUSD(model: "claude-fable-5-1", totals: million), 10, accuracy: 1e-9)
        XCTAssertEqual(table.estimateUSD(model: "claude-sonnet-5", totals: million), 2, accuracy: 1e-9)
        XCTAssertEqual(table.estimateUSD(model: "claude-sonnet-4-6", totals: million), 3, accuracy: 1e-9)
        XCTAssertEqual(table.estimateUSD(model: "claude-haiku-4-5", totals: million), 1, accuracy: 1e-9)
        XCTAssertEqual(table.estimateUSD(model: "claude-opus-4-7", totals: million), 5, accuracy: 1e-9)
    }

    func testLongestPrefixWinsWithDateSuffix() {
        let table = PricingTable.default
        XCTAssertEqual(table.rates(forModel: "claude-sonnet-4-6-20260115"), PricingTable.sonnet46)
        XCTAssertEqual(table.rates(forModel: "claude-sonnet-5-20260801"), PricingTable.sonnet5)
        XCTAssertEqual(table.rates(forModel: "claude-fable-5-1"), PricingTable.fable)

        let custom = PricingTable(
            ratesByPrefix: ["claude-x": PricingTable.haiku45, "claude-x-2": PricingTable.fable],
            fallback: PricingTable.opus
        )
        XCTAssertEqual(custom.rates(forModel: "claude-x-2-2026"), PricingTable.fable)
        XCTAssertEqual(custom.rates(forModel: "claude-x-1"), PricingTable.haiku45)
    }

    func testUnknownAndNilFallBackToOpus() {
        let table = PricingTable.default
        XCTAssertEqual(table.rates(forModel: nil), PricingTable.opus)
        XCTAssertEqual(table.rates(forModel: "mystery-model"), PricingTable.opus)
        XCTAssertEqual(table.estimateUSD(model: nil, totals: UsageTotals(outputTokens: 1_000_000)), 25, accuracy: 1e-9)
    }

    func testZeroUsageCostsNothing() {
        XCTAssertEqual(PricingTable.default.estimateUSD(model: "claude-opus-5", totals: .zero), 0)
    }
}
