import AgentBoardCore
import SwiftUI

/// The landing view: every project's board in one page, with no project open and no orchestrator
/// started. One observation covers the whole page — cards do not each query.
struct AtAGlanceView: View {
    let projects: [Project]
    let workspaces: [Workspace]
    let select: (SidebarSelection) -> Void

    @Environment(AppEnvironment.self) private var env
    @State private var summary = Observed<GlanceSummary>(.empty)
    @State private var confirmingShutdown = false
    @State private var windingDown = false

    private var sections: [GlanceGrouping.Section] {
        GlanceGrouping.sections(projects: projects, workspaces: workspaces, summary: summary.value)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headline
                ForEach(sections) { section in
                    sectionView(section)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .navigationTitle("At a Glance")
        .task {
            await summary.run(GlanceStore(env.db).observe(), in: env.db.reader)
        }
        .confirmationDialog(
            "Shut down every project and quit?",
            isPresented: $confirmingShutdown,
            titleVisibility: .visible
        ) {
            Button("Shut Down", role: .destructive) { windingDown = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(shutdownConfirmation)
        }
        .sheet(isPresented: $windingDown) {
            GlobalShutdownSheet()
                .environment(env)
        }
    }

    private var headline: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(GlanceHeadline.text(
                workingSessions: summary.value.workingSessions,
                tasksInReview: summary.value.tasksInReview
            ))
            .font(.title2)
            .fontWeight(.medium)
            Spacer()
            Button("Shut Down…") { confirmingShutdown = true }
                .help("Winds down every project's workers, then quits Agent Board.")
        }
    }

    /// Workers outlive the app: they are detached sessions that keep spending and keep committing
    /// if the app simply quits, which is the whole reason this control exists.
    private var shutdownConfirmation: String {
        let workers = GlanceHeadline.agents(summary.value.workingSessions).lowercased()
        return "\(workers) across \(projects.count == 1 ? "1 project" : "\(projects.count) projects"). "
            + "Each is told to commit its worktree and stop, and its unfinished task goes back to ready "
            + "with a resume note. Agent Board quits once they have all acknowledged."
    }

    private func sectionView(_ section: GlanceGrouping.Section) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = section.title {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 12, alignment: .top)], spacing: 12) {
                ForEach(section.cards) { card in
                    Button {
                        select(.project(card.id))
                    } label: {
                        ProjectGlanceCard(glance: card)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct ProjectGlanceCard: View {
    let glance: ProjectGlance

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(glance.name)
                .font(.headline)
                .lineLimit(1)
            if glance.isIdle {
                Text("Idle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 12) {
                    count(glance.running, "running")
                    count(glance.review, "in review")
                    count(glance.ready, "ready")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func count(_ value: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)")
                .font(.title3)
                .monospacedDigit()
                .foregroundStyle(value == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
