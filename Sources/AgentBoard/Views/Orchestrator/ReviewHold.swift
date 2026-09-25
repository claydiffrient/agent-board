import AgentBoardCore
import Foundation

/// Who a task in Pending reviews is waiting on (SPEC §10, Pending reviews).
enum ReviewHold: Equatable {
    case reviewing(reviewer: String, since: Date)
    /// The reviewer's turn or session ended with the task still in `review`, so it gave no verdict.
    case reviewerStopped(reviewer: String)
    /// `reason` is the board's own note on why no agent holds it.
    case waitingOnYou(reason: String?)

    /// What a reviewer that has left the roster is called.
    static let unknownReviewer = "Deleted agent"

    /// A reviewer is spawned after the worker completes and holds the task alone, so it is the
    /// newest session on the task; the completed worker never is once a reviewer has started.
    static func of(
        task: BoardTask, sessions: [AgentSession], roster: [RosterAgent], progress: [ProgressEntry]
    ) -> ReviewHold {
        let onTask = sessions.filter { $0.taskId == task.id }.sorted { $0.startedAt > $1.startedAt }
        let completedAt = onTask.first { $0.state == .completed }?.endedAt
        guard let reviewerId = task.reviewerAgentId else {
            return .waitingOnYou(reason: boardNote(.status, in: progress, since: completedAt))
        }
        guard let newest = onTask.first, newest.rosterAgentId == reviewerId, newest.state != .completed else {
            return .waitingOnYou(reason: boardNote(.error, in: progress, since: completedAt))
        }
        let name = roster.first { $0.id == reviewerId }?.name ?? unknownReviewer
        return newest.state.isActive && newest.state != .idle
            ? .reviewing(reviewer: name, since: newest.startedDate)
            : .reviewerStopped(reviewer: name)
    }

    /// `Board.complete` writes a human-review reason as a session-less `.status` row, and a
    /// reviewer that could not start leaves a session-less `.error` row.
    private static func boardNote(_ kind: AgentBoardCore.ProgressKind, in progress: [ProgressEntry], since: Int64?) -> String? {
        guard let since else { return nil }
        return progress
            .filter { $0.sessionId == nil && $0.kind == kind && $0.at >= since }
            .max { ($0.at, $0.id ?? 0) < ($1.at, $1.id ?? 0) }?
            .text
    }

    func label(now: Date) -> String {
        switch self {
        case .reviewing(let reviewer, let since):
            return "\(reviewer) reviewing · \(Format.elapsed(from: since, to: now))"
        case .reviewerStopped(let reviewer):
            return "\(reviewer) stopped without a verdict"
        case .waitingOnYou:
            return "Waiting on you"
        }
    }

    var endedWithoutVerdict: Bool {
        if case .reviewerStopped = self { return true }
        return false
    }

    var reason: String? {
        guard case .waitingOnYou(let reason) = self else { return nil }
        return reason
    }

    /// The confirmation a human decision needs first, or nil when no live reviewer would be cut off.
    func interruption(accepting: Bool) -> String? {
        guard case .reviewing(let reviewer, _) = self else { return nil }
        let verb = accepting ? "Accepting" : "Reopening"
        return "\(reviewer) is reviewing this task. \(verb) now stops \(reviewer)'s review."
    }
}
