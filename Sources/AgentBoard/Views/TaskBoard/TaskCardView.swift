import AgentBoardCore
import SwiftUI

struct TaskCardView: View {
    let task: BoardTask
    let epicTitle: String?
    let activeSession: AgentSession?
    let latestSession: AgentSession?
    let isSelected: Bool
    let onAccept: () -> Void
    let onReopen: () -> Void

    @Environment(AppEnvironment.self) private var env
    @State private var diffstat: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(task.title)
                    .font(.body.weight(.medium))
                    .lineLimit(3)
                Spacer(minLength: 4)
                if let priority = task.priority, !priority.isEmpty {
                    PriorityChip(priority: priority)
                }
                if let model = task.model { ModelChip(model: model) }
            }

            if let epicTitle {
                Label(epicTitle, systemImage: "flag")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let archived = task.archivedDate {
                Label("archived \(Format.relative(archived))", systemImage: "archivebox")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if task.blocked || task.failed {
                HStack(spacing: 4) {
                    if task.blocked {
                        FlagBadge(text: "blocked")
                            .help(task.blockedReason ?? "Blocked")
                    }
                    if task.failed {
                        FlagBadge(text: "failed")
                            .help(task.failureReason ?? "Failed")
                    }
                }
            }

            if let session = activeSession {
                agentSummary(session)
            }

            if task.column == .review {
                reviewDetails
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(task.isArchived ? 0.55 : 1)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: task.isArchived ? .underPageBackgroundColor : .controlBackgroundColor))
                .shadow(color: .black.opacity(task.isArchived ? 0 : 0.08), radius: 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isSelected ? Color.accentColor : (task.isArchived ? Color.secondary.opacity(0.4) : .clear),
                    style: StrokeStyle(lineWidth: 2, dash: task.isArchived && !isSelected ? [4, 3] : [])
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private func agentSummary(_ session: AgentSession) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                Text(session.displayShortId)
                    .monospaced()
                Text(session.state.label)
                    .foregroundStyle(session.state.color)
            }
            HStack(spacing: 4) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(session.elapsedText(at: context.date))
                        .monospacedDigit()
                }
                Text("·")
                Text("\(Format.cost(session.estCostUSD)) · \(Format.tokens(session.totalTokens)) tok")
            }
            .foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private var reviewDetails: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            if let branch = latestSession?.branch {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let worktree = latestSession?.worktreePath {
                Label(worktree, systemImage: "folder")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(worktree)
            }
            if let diffstat {
                Text(diffstat)
                    .font(.caption.monospaced())
                    .lineLimit(6)
            } else {
                Text("No diffstat available")
                    .foregroundStyle(.tertiary)
            }
            HStack {
                Button("Accept", action: onAccept)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Reopen", action: onReopen)
                    .controlSize(.small)
            }
            .padding(.top, 2)
        }
        .font(.caption)
        .task(id: task.id) {
            diffstat = await env.supervisor.worktreeDiffstat(taskId: task.id)
        }
    }
}

struct PriorityChip: View {
    let priority: String

    private var color: Color {
        switch priority.lowercased() {
        case "high", "urgent", "p0", "p1": .red
        case "medium", "normal", "p2": .orange
        case "low", "p3": .blue
        default: .secondary
        }
    }

    var body: some View {
        Text(priority)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }
}

struct FlagBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.red))
            .foregroundStyle(.white)
    }
}
