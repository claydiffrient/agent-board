import AgentBoardCore
import SwiftUI

struct EpicLaneHeader: View {
    let epic: Epic
    let count: EpicTaskCount
    let integrationPending: Bool
    let onRequestIntegration: () -> Void
    let onOpenPullRequest: () -> Void

    private var actions: [EpicLaneAction] {
        EpicLane.actions(state: epic.state, readyForIntegration: count.readyForIntegration)
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(epic.title)
                .font(.subheadline.weight(.semibold))
            EpicStateBadge(state: epic.state)
            Text(epic.branch)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text(count.label)
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.2)))
            ForEach(actions, id: \.self) { action in
                button(action)
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
        }
    }
}

struct EpicStateBadge: View {
    let state: EpicState

    var body: some View {
        Text(state.rawValue)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }

    private var color: Color {
        switch state {
        case .planning: .secondary
        case .active: .blue
        case .integrating: .orange
        case .done: .green
        case .abandoned: .red
        }
    }
}
