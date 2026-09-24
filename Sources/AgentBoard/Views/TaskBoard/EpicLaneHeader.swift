import AgentBoardCore
import SwiftUI

struct EpicLaneHeader: View {
    let epic: Epic
    let count: EpicTaskCount
    var pullRequest: PullRequestReference?
    let integrationPending: Bool
    let isCollapsed: Bool
    let onToggleCollapse: () -> Void
    let onRequestIntegration: () -> Void
    let onOpenPullRequest: () -> Void
    let onClose: (EpicClosure) -> Void

    private var actions: [EpicLaneAction] {
        EpicLane.actions(state: epic.state, readyForIntegration: count.readyForIntegration)
    }

    private var closures: [EpicClosure] { actions.compactMap(\.closure) }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggleCollapse) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCollapsed ? "Expand \(epic.title)" : "Collapse \(epic.title)")
            .help(isCollapsed ? "Expand this epic's lane" : "Collapse this epic's lane")
            Text(epic.title)
                .font(.subheadline.weight(.semibold))
            EpicStateBadge(state: epic.state, pullRequest: pullRequest)
            Text(epic.branch)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text(count.label)
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.2)))
            ForEach(actions.filter { $0.closure == nil }, id: \.self) { action in
                button(action)
            }
            if !closures.isEmpty {
                Menu {
                    ForEach(closures, id: \.self) { closure in
                        Button(closure.buttonLabel, role: .destructive) { onClose(closure) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("End \(epic.title)")
                .help("Finish or abandon this epic without integrating it. Nothing is merged and no branch is deleted.")
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func button(_ action: EpicLaneAction) -> some View {
        switch action {
        case .requestIntegration:
            Button(integrationPending ? "Integration requested" : "Request integration") {
                onRequestIntegration()
            }
            .controlSize(.small)
            .disabled(integrationPending)
            .help("Queues an approval. Nothing merges until you approve it in the approvals sidebar.")
        case .openPullRequest:
            Button("Open PR") { onOpenPullRequest() }
                .controlSize(.small)
                .help("Opens a prefilled pull request page in your browser. Agent Board never creates the PR.")
        case .closeAsDone, .abandon:
            EmptyView()
        }
    }
}

struct EpicStateBadge: View {
    let state: EpicState
    var pullRequest: PullRequestReference?

    var body: some View {
        Text(EpicLane.stateLabel(state: state, pullRequest: pullRequest))
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
            .help(pullRequest?.url ?? "")
    }

    private var color: Color {
        switch state {
        case .planning: .secondary
        case .active: .blue
        case .integrating: .orange
        case .pullRequestOpen: .purple
        case .done: .green
        case .abandoned: .red
        }
    }
}
