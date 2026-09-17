import Foundation

/// Which of the board's own sessions still hold a `claude --bg` process that nothing will ever stop.
///
/// The input is `agent_session` rows and nothing else. A `claude` process the board has no row for
/// cannot appear in the output, which is the whole point: argv, environment and working directory
/// cannot tell a parked spare from a live session, so they are never consulted.
public enum LeakedAgentSweep {
    public struct Decision: Sendable, Equatable {
        public enum Outcome: String, Sendable, Equatable {
            case stop
            case keep
        }

        public var sessionId: String
        public var shortId: String?
        public var outcome: Outcome
        public var reason: String

        public init(sessionId: String, shortId: String?, outcome: Outcome, reason: String) {
            self.sessionId = sessionId
            self.shortId = shortId
            self.outcome = outcome
            self.reason = reason
        }
    }

    /// One line per decision, keeps included, so a human can check the outcome rather than infer it
    /// from what vanished.
    public static func lines(_ report: AgentSweepReport) -> [String] {
        let verb = report.dryRun ? "WOULD-STOP" : "STOPPED"
        var lines = report.wouldStop.map { "\(verb) \($0.shortId ?? "-") \($0.sessionId) — \($0.reason)" }
        lines += report.stopped.map { "\(verb) \($0.shortId ?? "-") \($0.sessionId) — \($0.reason)" }
        lines += report.failed.map { "FAILED \($0.shortId ?? "-") \($0.sessionId) — \($0.reason)" }
        lines += report.kept.map { "KEPT \($0.shortId ?? "-") \($0.sessionId) — \($0.reason)" }
        lines.append(
            report.runtimeListed
                ? "UNTRACKED \(report.untracked) — live claude sessions the board has no row for, never touched"
                : "UNTRACKED unknown — the runtime could not be listed"
        )
        return lines
    }

    public static func plan(_ sessions: [AgentSession]) -> [Decision] {
        sessions.map { session in
            guard let shortId = session.shortId else {
                return Decision(
                    sessionId: session.sessionId,
                    shortId: nil,
                    outcome: .keep,
                    reason: "no short id: the board never learned of an agent for this row"
                )
            }
            guard !session.state.isActive else {
                return Decision(
                    sessionId: session.sessionId,
                    shortId: shortId,
                    outcome: .keep,
                    reason: "state \(session.state.rawValue) is active"
                )
            }
            return Decision(
                sessionId: session.sessionId,
                shortId: shortId,
                outcome: .stop,
                reason: "state \(session.state.rawValue) is inactive but the agent was never stopped"
            )
        }
    }
}

public struct AgentSweepReport: Sendable, Equatable {
    public var dryRun: Bool
    public var stopped: [LeakedAgentSweep.Decision] = []
    public var wouldStop: [LeakedAgentSweep.Decision] = []
    public var kept: [LeakedAgentSweep.Decision] = []
    public var failed: [LeakedAgentSweep.Decision] = []
    /// Live `claude` sessions with no `agent_session` row. Reported so the count of what was
    /// deliberately left alone is visible; never a candidate for anything.
    public var untracked = 0
    public var runtimeListed = false

    public init(dryRun: Bool) {
        self.dryRun = dryRun
    }

    public var lines: [String] { LeakedAgentSweep.lines(self) }
}
