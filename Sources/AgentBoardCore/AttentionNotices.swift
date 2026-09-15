import Foundation

/// Every Agent Board banner names its project. With several projects registered, "Worker may be
/// stuck" does not say where, and the short session id in the body does not help.
public enum NotificationText {
    public static func title(_ headline: String, project: String?) -> String {
        guard let project, !project.trimmingCharacters(in: .whitespaces).isEmpty else {
            return headline
        }
        return "\(headline) — \(project)"
    }
}

/// One banner the attention signal decided to raise.
public struct AttentionNotice: Sendable, Equatable, Identifiable {
    public var projectId: String
    public var reason: AttentionReason
    public var title: String
    public var body: String

    public init(projectId: String, reason: AttentionReason, title: String, body: String) {
        self.projectId = projectId
        self.reason = reason
        self.title = title
        self.body = body
    }

    public var id: String { "\(projectId)|\(reason.rawValue)" }
}

extension AttentionReason {
    /// The headline for this cause, before the project name is appended.
    func headline(count: Int) -> String {
        switch self {
        case .pendingApproval:
            return count == 1 ? "Approval waiting" : "\(count) approvals waiting"
        case .blockedWorker:
            return count == 1 ? "Worker blocked" : "\(count) workers blocked"
        case .strandedReports:
            return count == 1 ? "Report waiting" : "\(count) reports waiting"
        case .overdueShutdown:
            return "Shutdown not acknowledged"
        }
    }
}

/// Decides which banners the attention signal raises, and raises each one only on the transition
/// into its condition. Posts nothing itself, so both halves — whether to notify, and what the
/// banner says — are asserted without touching `UNUserNotificationCenter`.
///
/// Keyed by project and reason, not by the individual approval or task. A second approval arriving
/// while the first is still unanswered does not raise a second banner; the badge count is where a
/// growing queue shows. The key clears when that project stops having that reason, so the same
/// condition occurring again after it has been dealt with notifies again.
public struct AttentionNotifier: Sendable {
    /// The reasons worth interrupting a human for. `strandedReports` and `overdueShutdown` raise
    /// the sidebar badge without a banner: neither stops work the way an unanswered approval or a
    /// blocked worker does, and the shutdown sheet already tracks the stragglers.
    public static let notifying: Set<AttentionReason> = [.pendingApproval, .blockedWorker]

    private var announced: Set<String> = []

    public init() {}

    /// `focused` is the project whose screen the human is looking at right now, or nil when the app
    /// is in the background or sitting on At a Glance. Its banners are suppressed and still recorded
    /// as announced: the condition was on screen, so it must not resurface as a banner later.
    public mutating func notices(
        for attention: [ProjectAttention], focused: String? = nil
    ) -> [AttentionNotice] {
        var live: Set<String> = []
        var raised: [AttentionNotice] = []
        for project in attention {
            for cause in project.causes where Self.notifying.contains(cause.reason) {
                let notice = AttentionNotice(
                    projectId: project.id,
                    reason: cause.reason,
                    title: NotificationText.title(
                        cause.reason.headline(count: cause.count), project: project.name
                    ),
                    body: project.summary ?? cause.text
                )
                live.insert(notice.id)
                guard announced.insert(notice.id).inserted, project.id != focused else { continue }
                raised.append(notice)
            }
        }
        announced.formIntersection(live)
        return raised
    }
}
