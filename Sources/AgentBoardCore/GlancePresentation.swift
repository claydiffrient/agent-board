import Foundation

extension ProjectGlance {
    /// Nothing is moving, nothing is waiting, nothing is queued.
    public var isIdle: Bool { running == 0 && review == 0 && ready == 0 }
}

/// The one-line answer to "is anything happening, and does anything need me?".
///
/// Zero is a resting state, not a failure, so it is worded as reassurance ("Nothing running")
/// rather than as a count of absent things ("0 agents working").
public enum GlanceHeadline {
    public static func text(workingSessions: Int, tasksInReview: Int) -> String {
        if workingSessions == 0 && tasksInReview == 0 {
            return "Nothing running, and nothing is waiting on you."
        }
        return "\(agents(workingSessions)), \(review(tasksInReview))."
    }

    public static func agents(_ count: Int) -> String {
        switch count {
        case 0: "Nothing running"
        case 1: "1 agent working"
        default: "\(count) agents working"
        }
    }

    public static func review(_ count: Int) -> String {
        switch count {
        case 0: "nothing awaiting your review"
        case 1: "1 task awaiting your review"
        default: "\(count) tasks awaiting your review"
        }
    }
}

/// The At a Glance page's cards, grouped exactly as the sidebar groups its rows.
public enum GlanceGrouping {
    public struct Section: Identifiable, Sendable, Equatable {
        public var id: String
        public var title: String?
        public var cards: [ProjectGlance]

        public init(id: String, title: String?, cards: [ProjectGlance]) {
            self.id = id
            self.title = title
            self.cards = cards
        }
    }

    /// Sections in sidebar order, each holding a card for every project in the matching sidebar
    /// section — including projects the summary has not counted yet, which read as idle.
    /// `title` is nil for the ungrouped run when there are no workspaces at all, matching the
    /// sidebar's headerless section in that case.
    public static func sections(
        projects: [Project], workspaces: [Workspace], summary: GlanceSummary
    ) -> [Section] {
        let counts = Dictionary(summary.projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ProjectGrouping.sections(projects: projects, workspaces: workspaces).map { section in
            Section(
                id: section.id,
                title: section.isUngrouped && workspaces.isEmpty ? nil : section.workspace?.name ?? "Ungrouped",
                cards: section.projects.map { project in
                    counts[project.id] ?? ProjectGlance(id: project.id, name: project.name, running: 0, review: 0, ready: 0)
                }
            )
        }
    }
}
