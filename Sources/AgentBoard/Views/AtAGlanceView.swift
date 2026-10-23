import AgentBoardCore
import SwiftUI

/// The landing view: every project's board in one page, with no project open and no orchestrator
/// started. One observation covers the whole page — cards do not each query.
///
/// `attention` is handed down rather than observed here: `MainWindow` already runs the one
/// cross-project `ProjectAttentionStore.observeAll` that feeds the sidebar badges, so the page adds
/// no second observation of the same signal and cannot disagree with the sidebar about it.
struct AtAGlanceView: View {
    enum Mode: Hashable {
        case projects
        case processes
    }

    let projects: [Project]
    let workspaces: [Workspace]
    let attention: [ProjectAttention]
    var unreadReplies = 0
    var pullRequestCounts: [String: PRBadgeCount] = [:]
    let select: (SidebarSelection) -> Void
    /// Opens the Pull Requests page filtered to a project, or to every project for nil.
    var showPullRequests: (String?) -> Void = { _ in }

    @Environment(AppEnvironment.self) private var env
    @State private var summary = Observed<GlanceSummary>(.empty)
    @State private var confirmingShutdown = false
    @State private var windingDown = false
    /// Not remembered across visits: the page lands on Projects, so At a Glance itself never
    /// starts the process sampler (SPEC §10).
    @State var mode = Mode.projects

    private var sections: [GlanceGrouping.Section] {
        GlanceGrouping.sections(projects: projects, workspaces: workspaces, summary: summary.value)
    }

    private var attentionById: [String: ProjectAttention] {
        Dictionary(attention.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// `PRBadgeCount` already leaves out projects with follow-through off and paused watches, the
    /// sidebar badge's rule (SPEC §10).
    private var readyToVerify: [String: Int] {
        Self.readyToVerify(pullRequestCounts)
    }

    static func readyToVerify(_ counts: [String: PRBadgeCount]) -> [String: Int] {
        counts.compactMapValues { $0.readyToVerify > 0 ? $0.readyToVerify : nil }
    }

    /// The headline's clause filters to the one project it counts, and lists every project when
    /// it counts several.
    static func headlineFilter(_ ready: [String: Int]) -> String? {
        ready.count == 1 ? ready.keys.first : nil
    }

    private static let pullRequestsLink = URL(string: "agentboard-glance:pull-requests")!

    private var headlineText: AttributedString {
        let ready = readyToVerify.values.reduce(0, +)
        var text = AttributedString(GlanceHeadline.text(
            workingSessions: summary.value.workingSessions,
            tasksInReview: summary.value.tasksInReview,
            projectsNeedingYou: attention.filter(\.needsAttention).count,
            prsReadyToVerify: ready
        ))
        if let clause = GlanceHeadline.prsReadyToVerify(ready), let range = text.range(of: clause) {
            text[range].link = Self.pullRequestsLink
        }
        return text
    }

    var body: some View {
        content
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
        // The sheet that asked for the quit is gone by the time an attempt can fail — AppKit will
        // not terminate while it is up — so the refusal is reported here instead.
        .alert(
            "Agent Board is still running",
            isPresented: Binding(
                get: { env.quitter.refusal != nil },
                set: { if !$0 { env.quitter.dismissRefusal() } }
            ),
            presenting: env.quitter.refusal
        ) { _ in
            Button("Try Again") { env.quitter.requestQuit() }
            Button("OK", role: .cancel) {}
        } message: { Text($0) }
    }

    @ViewBuilder private var content: some View {
        switch mode {
        case .projects:
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    coordinatorCard
                    ForEach(sections) { section in
                        sectionView(section)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        case .processes:
            VStack(alignment: .leading, spacing: 0) {
                header.padding(20)
                ProcessInventoryView(projects: projects)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            headline
            Picker("Show", selection: $mode) {
                Text("Projects").tag(Mode.projects)
                Text("Processes").tag(Mode.processes)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    private var headline: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(headlineText)
                .font(.title2)
                .fontWeight(.medium)
                .environment(\.openURL, OpenURLAction { url in
                    guard url == Self.pullRequestsLink else { return .systemAction }
                    showPullRequests(Self.headlineFilter(readyToVerify))
                    return .handled
                })
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

    /// Sits beside the project cards so its spend reads against theirs (SPEC §10). It has no cap.
    private var coordinatorCard: some View {
        LazyVGrid(columns: Self.columns, spacing: 12) {
            Button {
                select(.coordinator)
            } label: {
                CoordinatorGlanceCard(spendUSD: summary.value.coordinatorSpendUSD, unreadReplies: unreadReplies)
            }
            .buttonStyle(.plain)
        }
    }

    private static let columns = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 12, alignment: .top)]

    private func sectionView(_ section: GlanceGrouping.Section) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = section.title {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: Self.columns, spacing: 12) {
                ForEach(section.cards) { card in
                    Button {
                        select(.project(card.id))
                    } label: {
                        ProjectGlanceCard(
                            glance: card, attention: attentionById[card.id],
                            readyToVerify: readyToVerify[card.id] ?? 0,
                            showPullRequests: { showPullRequests(card.id) }
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct ProjectGlanceCard: View {
    let glance: ProjectGlance
    let attention: ProjectAttention?
    var readyToVerify = 0
    var showPullRequests: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text(glance.name)
                    .font(.headline)
                    .lineLimit(1)
                if let reason = attention?.summary {
                    AttentionBadge(reason: reason)
                }
            }
            // A project waiting on an approval has an idle board and still needs a human, so the
            // badge stands alone rather than sitting beside "Idle".
            if glance.isIdle && attention?.needsAttention != true && readyToVerify == 0 {
                Text("Idle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if !glance.isIdle {
                HStack(spacing: 12) {
                    count(glance.running, "running")
                    count(glance.review, "in review")
                    count(glance.ready, "ready")
                }
            }
            if let clause = GlanceHeadline.prsReadyToVerify(readyToVerify) {
                Button(clause, action: showPullRequests)
                    .buttonStyle(.link)
                    .font(.callout)
                    .help("Open Pull Requests filtered to \(glance.name)")
            }
            if glance.spendUSD > 0 {
                Text("\(Format.cost(glance.spendUSD)) spent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

struct CoordinatorGlanceCard: View {
    let spendUSD: Double
    let unreadReplies: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("Coordinator")
                    .font(.headline)
                if let reason = CoordinatorRow.summary(unreadReplies: unreadReplies) {
                    AttentionBadge(reason: reason)
                }
            }
            Text("\(Format.cost(spendUSD)) spent")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
