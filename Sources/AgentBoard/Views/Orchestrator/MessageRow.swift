import AgentBoardCore
import SwiftUI

/// One cross-project message in the orchestrator sidebar. Read-only: the channel is between
/// orchestrators, and a human who wants to say something types it into that project's console.
struct MessageRow: View {
    let entry: MessageEntry
    let projectName: String

    @State private var expanded = false

    private var isReceived: Bool { entry.direction == .received }

    private var heading: String {
        isReceived ? "From \(entry.otherProjectName)" : "To \(entry.otherProjectName)"
    }

    private var consumptionLabel: String {
        entry.isConsumed ? "Read" : "Unread"
    }

    private var consumptionHelp: String {
        let reader = isReceived ? projectName : entry.otherProjectName
        return entry.isConsumed
            ? "\(reader)'s orchestrator has pulled this through list_reports."
            : "\(reader)'s orchestrator has not pulled this yet."
    }

    /// No way to measure the rendered height in a sidebar, so the toggle appears on length alone.
    private var isLong: Bool {
        entry.body.count > 200 || entry.body.split(separator: "\n", omittingEmptySubsequences: false).count > 4
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: isReceived ? "arrow.down.left" : "arrow.up.right")
                    .foregroundStyle(isReceived ? Color.blue : Color.secondary)
                Text(heading)
                    .fontWeight(entry.isConsumed ? .regular : .semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.callout)
            HStack(spacing: 6) {
                Text(consumptionLabel)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(entry.isConsumed ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.orange.opacity(0.25)), in: Capsule())
                    .foregroundStyle(entry.isConsumed ? Color.secondary : Color.orange)
                    .help(consumptionHelp)
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(Format.relative(entry.createdDate))
                }
                .help(entry.createdDate.formatted(date: .abbreviated, time: .standard))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(entry.body)
                .font(.caption)
                .foregroundStyle(entry.isConsumed ? .secondary : .primary)
                .textSelection(.enabled)
                .lineLimit(expanded ? nil : 4)
            if isLong {
                Button(expanded ? "Show less" : "Show more") { expanded.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
        .padding(.leading, entry.isConsumed ? 0 : 6)
        .overlay(alignment: .leading) {
            if !entry.isConsumed {
                Capsule()
                    .fill(Color.orange)
                    .frame(width: 2)
            }
        }
    }
}
