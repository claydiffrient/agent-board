import Foundation
import GRDB

/// What follow-through tells the owning project's orchestrator about one of its pull requests (SPEC §13.6).
/// The body never carries a comment or CI log: those are untrusted and long.
enum PRMilestone {
    case readyToVerify
    case parked(reason: String?)
    case unparked(reason: String)
    case decision(question: String?)
    case round(number: Int, outcome: PRRoundOutcome, pushedHeadOid: String? = nil)
    case merged
    case closed

    func body(_ watch: PRWatch) -> String {
        "#\(watch.number) \(watch.title) — \(watch.url)\n\(state): \(reason(watch))"
    }

    private var state: String {
        switch self {
        case .readyToVerify: "ready_to_verify"
        case .parked: "parked"
        case .unparked: "unparked"
        case .decision: "decision"
        case .round(_, let outcome, _): "round_\(outcome.rawValue)"
        case .merged: "merged"
        case .closed: "closed"
        }
    }

    private func reason(_ watch: PRWatch) -> String {
        switch self {
        case .readyToVerify:
            "approved, checks green and nothing open at \(watch.headOid.prefix(7))"
        case .parked(let reason):
            Self.oneLine(reason) ?? "parked"
        case .unparked(let reason):
            "\(Self.oneLine(reason) ?? "unparked"); now \(watch.state.rawValue)"
        case .decision(let question):
            Self.oneLine(question) ?? "a decision is waiting on the Pull Requests page"
        case .round(let number, .published, let sha):
            "round \(number) pushed \(sha.map { String($0.prefix(7)) } ?? "a fix")"
        case .round(let number, .stale, _):
            "round \(number) was not pushed: the head moved under it, so its fixes go back to triage"
        case .round(let number, .fixerFailed, _):
            "round \(number) ended without a fix: its fixer kept stopping without a report"
        case .round(let number, .triaged, _):
            "round \(number) triaged with nothing to fix"
        case .round(let number, let outcome, _):
            "round \(number) ended \(outcome.rawValue)"
        case .merged: "merged"
        case .closed: "closed without merging"
        }
    }

    private static func oneLine(_ text: String?) -> String? {
        guard let line = text?.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty })
        else { return nil }
        return line.count > 200 ? String(line.prefix(199)) + "…" : line
    }
}

extension PRWatchStore {
    /// Queues `milestone` for the project's orchestrator, unless the watch is paused or the project has
    /// follow-through off: the same gate as the banners (SPEC §13.4).
    static func report(_ db: Database, watch: PRWatch, _ milestone: PRMilestone) throws {
        guard !watch.paused,
              try Project.fetchOne(db, key: watch.projectId)?.settings.prFollowThrough.enabled == true
        else { return }
        _ = try ReportStore.insert(
            db, projectId: watch.projectId, taskId: nil, sessionId: nil, kind: .prFollowThrough, body: milestone.body(watch)
        )
    }
}
