import AgentBoardCore
import SwiftUI

struct EpicLaneHeader: View {
    let epic: Epic
    let count: EpicTaskCount
    var pullRequest: PullRequestReference?
    let integrationPending: Bool
    let isCollapsed: Bool
    let archivable: Int
    let onToggleCollapse: () -> Void
    let onArchive: () -> Void
    let onRequestIntegration: () -> Void
    let onOpenPullRequest: () -> Void
    let onClose: (EpicClosure) -> Void
    let onRemoveWorktrees: () -> Void

    private var actions: [EpicLaneAction] {
        EpicLane.actions(state: epic.state, readyForIntegration: count.readyForIntegration)
    }

    private var menuActions: [EpicLaneAction] { actions.filter(\.isInMenu) }

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
            ForEach(actions.filter { !$0.isInMenu }, id: \.self) { action in
                button(action)
            }
            if archivable > 0 {
                Button(TaskArchive.buttonTitle(count: archivable), action: onArchive)
                    .controlSize(.small)
                    .help("Hide this epic's done tasks from the board. Nothing is deleted; with all of them archived the lane leaves the board until Show Archived is on.")
            }
            if !menuActions.isEmpty {
                Menu {
                    ForEach(menuActions, id: \.self) { action in
                        if let closure = action.closure {
                            Button(closure.buttonLabel, role: .destructive) { onClose(closure) }
                        } else {
                            Button("Remove worktrees…", role: .destructive) { onRemoveWorktrees() }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(epic.state.isTerminal ? "Clean up \(epic.title)" : "End \(epic.title)")
                .help(epic.state.isTerminal
                    ? "Remove the worktrees this epic left on disk, running the project's teardown hook. No branch is deleted."
                    : "Finish or abandon this epic without integrating it. Nothing is merged and no branch is deleted.")
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
        case .closeAsDone, .abandon, .removeWorktrees:
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
        case .integrated: .teal
        case .pullRequestOpen: .purple
        case .done: .green
        case .abandoned: .red
        }
    }
}
