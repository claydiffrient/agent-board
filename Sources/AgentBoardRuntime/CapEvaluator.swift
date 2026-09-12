import Foundation

public struct CapLimits: Sendable, Equatable {
    public var maxTokens: Int
    public var maxWallClockSeconds: Int
    public var maxIdleSeconds: Int

    public static let `default` = CapLimits(maxTokens: 150_000, maxWallClockSeconds: 30 * 60, maxIdleSeconds: 5 * 60)

    public init(maxTokens: Int, maxWallClockSeconds: Int, maxIdleSeconds: Int) {
        self.maxTokens = maxTokens
        self.maxWallClockSeconds = maxWallClockSeconds
        self.maxIdleSeconds = maxIdleSeconds
    }
}

public enum CapBreach: Sendable, Equatable {
    case tokens(used: Int, limit: Int)
    case wallClock(elapsed: TimeInterval, limit: TimeInterval)
    case idle(since: Date, limit: TimeInterval)
}

public enum CapEvaluator {
    /// Cache reads are excluded from the token count: they are cheap and re-sent on every turn,
    /// so counting them would exhaust the cap on conversation length rather than on work done.
    public static func countedTokens(_ totals: UsageTotals) -> Int {
        totals.inputTokens + totals.outputTokens + totals.cacheWriteTokens
    }

    /// Checks tokens, then wall clock, then idle; a missing `lastActivity` idles from `startedAt`.
    public static func evaluate(
        totals: UsageTotals,
        startedAt: Date,
        lastActivity: Date?,
        now: Date,
        limits: CapLimits
    ) -> CapBreach? {
        let used = countedTokens(totals)
        if used >= limits.maxTokens {
            return .tokens(used: used, limit: limits.maxTokens)
        }
        let elapsed = now.timeIntervalSince(startedAt)
        if elapsed >= TimeInterval(limits.maxWallClockSeconds) {
            return .wallClock(elapsed: elapsed, limit: TimeInterval(limits.maxWallClockSeconds))
        }
        let since = lastActivity ?? startedAt
        if now.timeIntervalSince(since) >= TimeInterval(limits.maxIdleSeconds) {
            return .idle(since: since, limit: TimeInterval(limits.maxIdleSeconds))
        }
        return nil
    }
}
