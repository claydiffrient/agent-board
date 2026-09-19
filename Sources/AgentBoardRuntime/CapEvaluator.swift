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
    /// Named for `maxWallClockSeconds`, the setting it enforces, but measured on awake time.
    case wallClock(elapsed: TimeInterval, limit: TimeInterval)
    case idle(since: Date, limit: TimeInterval)
}

public enum CapEvaluator {
    /// Only uncached input and output count. Cache reads recur every turn, and cache writes spike
    /// by the whole context on every resume, so neither measures work done.
    public static func countedTokens(_ totals: UsageTotals) -> Int {
        totals.inputTokens + totals.outputTokens
    }

    /// Checks tokens, then elapsed, then idle; a missing `lastActivity` idles from `startedAt`.
    ///
    /// Both time caps bound how long an agent has been *working*, so they are measured on
    /// `AwakeElapsed` rather than the wall clock. A worker on a sleeping laptop is suspended, not
    /// idle: closing the lid used to execute every running worker at the idle cap.
    ///
    /// `state` only excuses the idle check. A session that is waiting on a file lock, blocked, or
    /// still in setup makes no tool call by design, and killing it would throw away exactly the work
    /// it is waiting to do; the token and elapsed caps still apply to it unchanged. `toolStartedAt`
    /// excuses it the same way for as long as `ToolCallGrace` allows one call to run.
    public static func evaluate(
        totals: UsageTotals,
        startedAt: Date,
        lastActivity: Date?,
        toolStartedAt: Date? = nil,
        awake: AwakeElapsed,
        limits: CapLimits,
        state: SessionState = .running
    ) -> CapBreach? {
        let used = countedTokens(totals)
        if let maxTokens = limits.maxTokens, used >= maxTokens {
            return .tokens(used: used, limit: maxTokens)
        }
        let elapsed = awake.secondsAwake(since: startedAt)
        if elapsed >= TimeInterval(limits.maxWallClockSeconds) {
            return .wallClock(elapsed: elapsed, limit: TimeInterval(limits.maxWallClockSeconds))
        }
        guard !state.idlesByDesign else { return nil }
        let since = lastActivity ?? startedAt
        guard awake.secondsAwake(since: since) >= TimeInterval(limits.maxIdleSeconds) else { return nil }
        // Checked after the breach, never instead of it: a `tool_started_at` left behind by a
        // `PostToolUse` that never arrived can cost a worker its grace, never its life.
        guard !ToolCallGrace.excusesSilence(
            toolStartedAt: toolStartedAt, awake: awake, threshold: TimeInterval(limits.maxIdleSeconds)
        ) else { return nil }
        return .idle(since: since, limit: TimeInterval(limits.maxIdleSeconds))
    }
}
