import AgentBoardCore
import SwiftUI

/// The sidebar's "look here" mark.
///
/// A dot, not a count. `ProjectAttention.count` sums heterogeneous causes, so a "3" would mean
/// one approval plus two blocked workers and read as a precision it does not have; and the row
/// has roughly 20 points to spare beside the gear at the sidebar's 180-point minimum. The dot
/// says only "open this one", and the tooltip carries the sentence that answers why.
struct AttentionBadge: View {
    let reason: String

    /// Wide enough to hover, small enough not to push on the gear.
    private static let hitSize: CGFloat = 12

    var body: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: 7))
            .foregroundStyle(.orange)
            .frame(width: Self.hitSize, height: Self.hitSize)
            .contentShape(Rectangle())
            .help(reason)
            .accessibilityLabel("Needs attention. \(reason)")
    }
}

/// One project in the sidebar: its name, the attention badge when it is waiting on a human, and
/// the settings gear. Kept out of `MainWindow` so a render test can mount a row on its own.
struct ProjectRow: View {
    let project: Project
    let attention: ProjectAttention?
    let openSettings: () -> Void

    var body: some View {
        HStack {
            Label(project.name, systemImage: "folder")
                .help(project.repoPath)
                .layoutPriority(1)
            Spacer(minLength: 4)
            if let summary = attention?.summary {
                AttentionBadge(reason: summary)
            }
            Button(action: openSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Project settings")
        }
    }
}

/// The Coordinator's pinned sidebar row: marked while replies wait in its queue unread (SPEC §9.4).
struct CoordinatorRow: View {
    let unreadReplies: Int
    let openSettings: () -> Void

    static func unreadReplies(_ queue: [Report]) -> Int {
        queue.filter { $0.kind == .reply }.count
    }

    static func summary(unreadReplies: Int) -> String? {
        switch unreadReplies {
        case 0: nil
        case 1: "1 reply the Coordinator has not read"
        default: "\(unreadReplies) replies the Coordinator has not read"
        }
    }

    var body: some View {
        HStack {
            Label("Coordinator", systemImage: "point.3.connected.trianglepath.dotted")
                .layoutPriority(1)
            Spacer(minLength: 4)
            if let summary = Self.summary(unreadReplies: unreadReplies) {
                AttentionBadge(reason: summary)
            }
            Button(action: openSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Coordinator settings")
        }
    }
}

/// What a collapsed section's badge says: every waiting project inside it, one per line, so the
/// tooltip answers "which one" as well as "why" without expanding the section.
func collapsedSectionSummary(_ section: ProjectSection, attention: [String: ProjectAttention]) -> String? {
    let lines = section.projects.compactMap { project -> String? in
        guard let summary = attention[project.id]?.summary else { return nil }
        return "\(project.name): \(summary)"
    }
    return lines.isEmpty ? nil : lines.joined(separator: "\n")
}
