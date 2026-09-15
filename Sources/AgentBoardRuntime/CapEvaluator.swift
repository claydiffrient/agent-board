import AgentBoardCore
import Foundation

public struct CapLimits: Sendable, Equatable {
    public var maxTokens: Int?
    public var maxWallClockSeconds: Int
    public var maxIdleSeconds: Int

    public static let `default` = CapLimits(maxTokens: nil, maxWallClockSeconds: 30 * 60, maxIdleSeconds: 5 * 60)

    public init(maxTokens: Int?, maxWallClockSeconds: Int, maxIdleSeconds: Int) {
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
    /// Only uncached input and output count. Cache reads recur every turn, and cache writes spike
    /// by the whole context on every resume, so neither measures work done.
    public static func countedTokens(_ totals: UsageTotals) -> Int {
        totals.inputTokens + totals.outputTokens
    }

    /// Checks tokens, then wall clock, then idle; a missing `lastActivity` idles from `startedAt`.
    ///
    /// `state` only excuses the idle check. A session that is waiting on a file lock, blocked, or
    /// still in setup makes no tool call by design, and killing it would throw away exactly the work
    /// it is waiting to do; the token and wall-clock caps still apply to it unchanged.
    public static func evaluate(
        totals: UsageTotals,
        startedAt: Date,
        lastActivity: Date?,
        now: Date,
        limits: CapLimits,
        state: SessionState = .running
    ) -> CapBreach? {
        let used = countedTokens(totals)
        if let maxTokens = limits.maxTokens, used >= maxTokens {
            return .tokens(used: used, limit: maxTokens)
        }
        let elapsed = now.timeIntervalSince(startedAt)
        if elapsed >= TimeInterval(limits.maxWallClockSeconds) {
            return .wallClock(elapsed: elapsed, limit: TimeInterval(limits.maxWallClockSeconds))
        }
        guard !state.idlesByDesign else { return nil }
        let since = lastActivity ?? startedAt
        if now.timeIntervalSince(since) >= TimeInterval(limits.maxIdleSeconds) {
            return .idle(since: since, limit: TimeInterval(limits.maxIdleSeconds))
        }
        return nil
    }
}
