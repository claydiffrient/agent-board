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
        XCTAssertEqual(table.rates(forModel: "claude-fable-5-1"), PricingTable.fable51)

        let custom = PricingTable(
            ratesByPrefix: ["claude-x": PricingTable.haiku45, "claude-x-2": PricingTable.fable51],
            fallback: PricingTable.opus
        )
        XCTAssertEqual(custom.rates(forModel: "claude-x-2-2026"), PricingTable.fable51)
        XCTAssertEqual(custom.rates(forModel: "claude-x-1"), PricingTable.haiku45)
    }

    func testOpus55HasItsOwnRatesNotOpus5s() {
        let table = PricingTable.default
        let opus55 = ModelRates(inputPerMTok: 4, outputPerMTok: 20, cacheRead: 0.2, cacheWrite5m: 5, cacheWrite1h: 8)
        XCTAssertEqual(table.rates(forModel: "claude-opus-5-5"), opus55)
        XCTAssertEqual(table.rates(forModel: "claude-opus-5-5-20260101"), opus55)
        XCTAssertNotEqual(table.rates(forModel: "claude-opus-5-5"), PricingTable.opus)

        let opus5 = ModelRates(inputPerMTok: 5, outputPerMTok: 25, cacheRead: 0.5, cacheWrite5m: 6.25, cacheWrite1h: 10)
        XCTAssertEqual(table.rates(forModel: "claude-opus-5"), opus5)
        XCTAssertEqual(table.rates(forModel: "claude-opus-5-20260101"), opus5)
    }

    func testNewestModelsHaveTheirOwnPublishedRates() {
        let table = PricingTable.default
        XCTAssertEqual(
            table.rates(forModel: "claude-haiku-5-5"),
            ModelRates(inputPerMTok: 0.1, outputPerMTok: 0.5, cacheRead: 0.01, cacheWrite5m: 0.125, cacheWrite1h: 0.2)
        )
        XCTAssertEqual(
            table.rates(forModel: "claude-fable-5-2"),
            ModelRates(inputPerMTok: 8, outputPerMTok: 40, cacheRead: 0.2, cacheWrite5m: 10, cacheWrite1h: 16)
        )
        XCTAssertEqual(
            table.rates(forModel: "claude-fable-5"),
            ModelRates(inputPerMTok: 10, outputPerMTok: 50, cacheRead: 1, cacheWrite5m: 12.5, cacheWrite1h: 20)
        )
        XCTAssertEqual(
            table.rates(forModel: "claude-sonnet-5-5"),
            ModelRates(inputPerMTok: 2, outputPerMTok: 10, cacheRead: 0.1, cacheWrite5m: 2.5, cacheWrite1h: 4)
        )
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
