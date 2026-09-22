import AgentBoardCore
import Foundation

/// Where a banner click lands. Every notification carries one of these in its `userInfo`, so the
/// click can open the project the banner is about on the screen that shows the thing it names,
/// rather than dismissing and leaving the human to find it.
struct NotificationRoute: Equatable, Hashable {
    /// What the banner is about, and the identifier that pins it down when there is one.
    enum Subject: Equatable, Hashable {
        case approvals
        /// A task a worker blocked on. The id is absent when the signal only counted them.
        case blockedTask(String?)
        /// A session that went blocked without a task, so no task card names it.
        case session(String)
        case reports
        case shutdown
        /// The project's shell console — a human's own `npm run dev`, not an agent's.
        case terminal
        /// The banner names no subject beyond its project.
        case project
    }

    var projectId: String
    var subject: Subject

    init(projectId: String, subject: Subject = .project) {
        self.projectId = projectId
        self.subject = subject
    }

    init(_ notice: AttentionNotice, subjectId: String? = nil) {
        self.init(projectId: notice.projectId, subject: Self.subject(for: notice.reason, id: subjectId))
    }

    static func subject(for reason: AttentionReason, id: String? = nil) -> Subject {
        switch reason {
        case .pendingApproval: .approvals
        case .blockedWorker: .blockedTask(id)
        case .strandedReports: .reports
        case .overdueShutdown: .shutdown
        }
    }

    /// Approvals, blocked tasks and the shutdown sheet all live on the Orchestrator screen — the
    /// approvals sidebar carries both the pending queue and the blocked-task section — and the
    /// console is what drains queued reports. A session with no task appears only in the Status
    /// roster, and the shell console only on Terminal, so those two land elsewhere.
    var screen: ProjectDetailView.Screen {
        switch subject {
        case .session: .status
        case .terminal: .terminal
        case .approvals, .blockedTask, .reports, .shutdown, .project: .orchestrator
        }
    }
}

extension NotificationRoute {
    enum Key {
        static let projectId = "agentboard.projectId"
        static let subject = "agentboard.subject"
        static let subjectId = "agentboard.subjectId"
    }

    var userInfo: [String: String] {
        var info = [Key.projectId: projectId, Key.subject: subject.kind]
        if let id = subject.identifier { info[Key.subjectId] = id }
        return info
    }

    /// A payload without a project id routes nowhere and is rejected. An unrecognised subject is
    /// not: a banner posted by an older build should still open its project.
    init?(userInfo: [AnyHashable: Any]) {
        guard let projectId = userInfo[Key.projectId] as? String, !projectId.isEmpty else { return nil }
        let id = userInfo[Key.subjectId] as? String
        let kind = userInfo[Key.subject] as? String ?? ""
        self.init(projectId: projectId, subject: Subject(kind: kind, id: id))
    }
}

extension NotificationRoute.Subject {
    var kind: String {
        switch self {
        case .approvals: "approvals"
        case .blockedTask: "blockedTask"
        case .session: "session"
        case .reports: "reports"
        case .shutdown: "shutdown"
        case .terminal: "terminal"
        case .project: "project"
        }
    }

    var identifier: String? {
        switch self {
        case .blockedTask(let id): id
        case .session(let id): id
        case .approvals, .reports, .shutdown, .terminal, .project: nil
        }
    }

    init(kind: String, id: String?) {
        switch kind {
        case "approvals": self = .approvals
        case "blockedTask": self = .blockedTask(id)
        case "session": self = id.map(Self.session) ?? .project
        case "reports": self = .reports
        case "shutdown": self = .shutdown
        case "terminal": self = .terminal
        default: self = .project
        }
    }
}
