import Foundation

/// USD per million tokens. List prices, not billed amounts.
public struct ModelRates: Sendable, Equatable {
    public var inputPerMTok: Double
    public var outputPerMTok: Double
    public var cacheRead: Double
    public var cacheWrite5m: Double
    public var cacheWrite1h: Double

    public init(inputPerMTok: Double, outputPerMTok: Double, cacheRead: Double, cacheWrite5m: Double, cacheWrite1h: Double) {
        self.inputPerMTok = inputPerMTok
        self.outputPerMTok = outputPerMTok
        self.cacheRead = cacheRead
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
    }

    public func estimateUSD(_ totals: UsageTotals) -> Double {
        (Double(totals.inputTokens) * inputPerMTok
            + Double(totals.outputTokens) * outputPerMTok
            + Double(totals.cacheReadTokens) * cacheRead
            + Double(totals.cacheWrite5mTokens) * cacheWrite5m
            + Double(totals.cacheWrite1hTokens) * cacheWrite1h) / 1_000_000
    }
}

public struct PricingTable: Sendable {
    public var ratesByPrefix: [String: ModelRates]
    public var fallback: ModelRates

    public init(ratesByPrefix: [String: ModelRates], fallback: ModelRates) {
        self.ratesByPrefix = ratesByPrefix
        self.fallback = fallback
    }

    public static let fable52 = ModelRates(inputPerMTok: 8, outputPerMTok: 40, cacheRead: 0.2, cacheWrite5m: 10, cacheWrite1h: 16)
    public static let fable51 = ModelRates(inputPerMTok: 10, outputPerMTok: 50, cacheRead: 0.25, cacheWrite5m: 12.5, cacheWrite1h: 20)
    public static let fable5 = ModelRates(inputPerMTok: 10, outputPerMTok: 50, cacheRead: 1, cacheWrite5m: 12.5, cacheWrite1h: 20)
    public static let opus = ModelRates(inputPerMTok: 5, outputPerMTok: 25, cacheRead: 0.5, cacheWrite5m: 6.25, cacheWrite1h: 10)
    /// Cache reads are 0.05x input here, not the usual 0.1x.
    public static let opus55 = ModelRates(inputPerMTok: 4, outputPerMTok: 20, cacheRead: 0.2, cacheWrite5m: 5, cacheWrite1h: 8)
    public static let sonnet55 = ModelRates(inputPerMTok: 2, outputPerMTok: 10, cacheRead: 0.1, cacheWrite5m: 2.5, cacheWrite1h: 4)
    public static let sonnet5 = ModelRates(inputPerMTok: 2, outputPerMTok: 10, cacheRead: 0.2, cacheWrite5m: 2.5, cacheWrite1h: 4)
    public static let sonnet46 = ModelRates(inputPerMTok: 3, outputPerMTok: 15, cacheRead: 0.3, cacheWrite5m: 3.75, cacheWrite1h: 6)
    /// Rates for prompts up to 100K tokens; longer prompts bill 5x every field, which a per-model table can't express.
    public static let haiku55 = ModelRates(inputPerMTok: 0.1, outputPerMTok: 0.5, cacheRead: 0.01, cacheWrite5m: 0.125, cacheWrite1h: 0.2)
    public static let haiku45 = ModelRates(inputPerMTok: 1, outputPerMTok: 5, cacheRead: 0.1, cacheWrite5m: 1.25, cacheWrite1h: 2)

    public static let `default` = PricingTable(
        ratesByPrefix: [
            "claude-fable-5-2": fable52,
            "claude-fable-5-1": fable51,
            "claude-fable-5": fable5,
            "claude-opus-5-5": opus55,
            "claude-opus-5": opus,
            "claude-opus-4-8": opus,
            "claude-opus-4-7": opus,
            "claude-opus-4-6": opus,
            "claude-sonnet-5-5": sonnet55,
            "claude-sonnet-5": sonnet5,
            "claude-sonnet-4-6": sonnet46,
            "claude-haiku-5-5": haiku55,
            "claude-haiku-4-5": haiku45,
        ],
        fallback: opus
    )

    /// Longest-prefix match; model ids may carry date suffixes. Unknown or nil falls back to opus rates.
    public func rates(forModel model: String?) -> ModelRates {
        guard let model else { return fallback }
        let match = ratesByPrefix
            .filter { model.hasPrefix($0.key) }
            .max { $0.key.count < $1.key.count }
        return match?.value ?? fallback
    }

    public func estimateUSD(model: String?, totals: UsageTotals) -> Double {
        rates(forModel: model).estimateUSD(totals)
    }
}
