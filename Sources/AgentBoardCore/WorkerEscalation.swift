import Foundation
import GRDB

/// SPEC §5 retries: a task whose last attempt fell short runs one effort level higher, then one model up.
public enum WorkerEscalation {
    public enum Shortfall: Sendable, Equatable {
        /// Ended `failed`: a cap, or the worker's own `report_failed`.
        case failed
        case reviewReopened
    }

    /// The newest worker attempt that says something about the model, and how it fell short.
    public struct Prior: Sendable, Equatable {
        public var attempt: Int
        public var model: String?
        public var effort: Effort?
        public var shortfall: Shortfall

        public init(attempt: Int, model: String?, effort: Effort?, shortfall: Shortfall) {
            self.attempt = attempt
            self.model = model
            self.effort = effort
            self.shortfall = shortfall
        }
    }

    /// Reads `taskId`'s sessions and its latest agent-review verdict. `cutBySleep` says whether a session's
    /// last turn ended on a system-sleep cut, which only the hook log records.
    public static func prior(
        in db: AppDatabase, taskId: String, cutBySleep: (AgentSession) -> Bool
    ) throws -> Prior? {
        let (sessions, verdict) = try db.reader.read { db in
            let sessions = try AgentSession.fetchAll(
                db, sql: "SELECT * FROM agent_session WHERE task_id = ? ORDER BY started_at DESC, attempt DESC",
                arguments: [taskId]
            )
            let verdict = try ProgressStore.latestReviewVerdict(db, taskId: taskId)
            return (sessions, verdict)
        }
        let reopenedAt = verdict.flatMap { $0.text.hasPrefix(Board.reviewFailedLead) ? $0.at : nil }
        return prior(sessions: sessions, reviewReopenedAt: reopenedAt, cutBySleep: cutBySleep)
    }

    /// Setup failures, stops that were not caps, hand-offs and sleep cuts say nothing about the model and
    /// are skipped; a completed attempt no review reopened since it started ends the search with nil.
    static func prior(
        sessions: [AgentSession], reviewReopenedAt: Int64?, cutBySleep: (AgentSession) -> Bool
    ) -> Prior? {
        for session in sessions where session.role == .worker && session.reviewHead == nil {
            let found = { (shortfall: Shortfall) in
                Prior(attempt: session.attempt, model: session.model, effort: session.effort, shortfall: shortfall)
            }
            switch session.state {
            case .failed:
                let reason = session.stopReason
                if SessionTermination.isSetupFailure(reason)
                    || reason?.hasPrefix(SessionTermination.setupStopUnconfirmedLead) == true
                    || cutBySleep(session) {
                    continue
                }
                return found(.failed)
            case .completed:
                if session.stopReason?.hasPrefix("handed off") == true { continue }
                if let at = reviewReopenedAt, at >= session.startedAt { return found(.reviewReopened) }
                return nil
            default:
                continue
            }
        }
        return nil
    }

    /// One step up from `prior` for each value `choice` took from a default; an explicit value is kept.
    public static func escalate(
        _ choice: WorkerModelChoice, after prior: Prior, attempt: Int, allowsFable: Bool
    ) -> WorkerModelChoice {
        guard !humanRaisedDefault(choice, above: prior) else { return choice }
        let modelFree = choice.modelSource.isDefault
        let effortFree = choice.effortSource.isDefault
        guard modelFree || effortFree else { return choice }
        let model = modelFree ? prior.model ?? choice.model : choice.model
        let effort = effortFree ? prior.effort ?? choice.effort : choice.effort
        var next = choice
        let step: String
        if effortFree, let raised = raise(effort) {
            next.model = model
            next.effort = raised
            step = "effort \(effort?.rawValue ?? "Claude Code's default") → \(raised.rawValue)"
        } else if modelFree, let model, let up = nextModel(after: model, allowsFable: allowsFable) {
            next.model = up
            next.effort = effortFree ? .medium : effort
            step = "model \(model) → \(up) at \(next.effort?.rawValue ?? "Claude Code's default") effort"
        } else {
            next.model = model
            next.effort = effort
            let fable = modelFree && model.map(isOpus) == true && !allowsFable ? " (Allow escalation to Fable is off)" : ""
            step = "stays on \(model ?? "Claude Code's default model") at "
                + "\(effort?.rawValue ?? "Claude Code's default") effort, the top of its ladder\(fable)"
        }
        if next.model != choice.model { next.modelSource = .escalation }
        if next.effort != choice.effort { next.effortSource = .escalation }
        let cause = switch prior.shortfall {
        case .failed: "attempt \(prior.attempt) failed"
        case .reviewReopened: "review reopened attempt \(prior.attempt)"
        }
        next.escalation = "attempt \(attempt): \(step) after \(cause)"
        return next
    }

    /// A type-table or project default the human raised past what the last attempt ran at.
    static func humanRaisedDefault(_ choice: WorkerModelChoice, above prior: Prior) -> Bool {
        func human(_ source: WorkerModelSource) -> Bool { source == .typeTable || source == .projectDefault }
        if human(choice.modelSource), let fresh = choice.model.flatMap(modelRank),
           let last = prior.model.flatMap(modelRank), fresh > last {
            return true
        }
        if human(choice.effortSource), let fresh = choice.effort,
           let last = Effort.allCases.firstIndex(of: prior.effort ?? .medium),
           let now = Effort.allCases.firstIndex(of: fresh), now > last {
            return true
        }
        return false
    }

    private static func modelRank(_ model: String) -> Int? {
        ["claude-haiku-", "claude-sonnet-", "claude-opus-", "claude-fable-"].firstIndex { model.hasPrefix($0) }
    }

    /// Up to `xhigh`; Claude Code's own default effort is read as `medium`.
    static func raise(_ effort: Effort?) -> Effort? {
        switch effort {
        case nil, .medium: return .high
        case .low: return .medium
        case .high: return .xhigh
        case .xhigh, .max: return nil
        }
    }

    static func nextModel(after model: String, allowsFable: Bool) -> String? {
        if model.hasPrefix("claude-haiku-") { return "claude-sonnet-5-5" }
        if model.hasPrefix("claude-sonnet-") { return "claude-opus-5-5" }
        if isOpus(model) { return allowsFable ? "claude-fable-5-2" : nil }
        return nil
    }

    private static func isOpus(_ model: String) -> Bool { model.hasPrefix("claude-opus-") }
}
