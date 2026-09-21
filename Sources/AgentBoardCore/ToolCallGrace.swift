import Foundation

/// A tool call that has started but not returned is work, not silence.
///
/// `PostToolUse` fires only when the tool returns, so a single long command — a cold `swift build`
/// on this project measures 544s — writes no hook for its whole duration and every deadline read
/// off `last_activity` fires while the worker is doing exactly what it was told to do.
///
/// The grace is a multiple of whatever deadline it extends rather than one fixed ceiling, so the
/// stall indicator still surfaces a wedged call (120s → 720s) before the idle cap kills it
/// (300s → 1800s), and a project that edits either number keeps that ordering for free.
public enum ToolCallGrace {
    /// 6× the deadline. The longest legitimate single command measured here is a cold `swift build`
    /// at 544s, and a cold build followed by the full `swift test` in one command roughly doubles
    /// it; 6 × the 300s idle default is 1800s, which covers that and is exactly the default elapsed
    /// cap, so the grace can never outlive the backstop that reaps a wedged worker regardless.
    public static let multiplier: Double = 6

    /// How long an in-flight call may run before `threshold` applies to it after all. Finite by
    /// construction: a call that never returns breaches here.
    public static func deadline(extending threshold: TimeInterval) -> TimeInterval {
        threshold * multiplier
    }

    /// Whether a call started at `toolStartedAt` still excuses `threshold` of silence. Callers use
    /// this to *extend* a deadline they have already found breached, never to trigger one: a
    /// `tool_started_at` left behind by a `PostToolUse` that never arrived can then cost a worker
    /// its grace, never its life.
    public static func excusesSilence(
        toolStartedAt: Date?,
        awake: AwakeElapsed,
        threshold: TimeInterval
    ) -> Bool {
        guard let toolStartedAt else { return false }
        return awake.secondsAwake(since: toolStartedAt) < deadline(extending: threshold)
    }
}
