import AgentBoardCore
import SwiftUI

struct StatusView: View {
    let project: Project

    @Environment(AppEnvironment.self) private var env
    @State private var status = Observed(StatusSnapshot())
    @State private var tasks = Observed<[BoardTask]>([])
    @State private var serverPort: Int?
    @State private var lastError: String?
    @State private var errorMessage: String?
    @State private var now = Date()
    @State private var query = ""
    @AppStorage("status.showEndedSessions") private var showEnded = false

    private var taskTitles: [String: String] {
        Dictionary(uniqueKeysWithValues: tasks.value.map { ($0.id, $0.title) })
    }

    private var sessions: [AgentSession] { status.value.sessions }

    private var roster: SessionRoster {
        SessionVisibility.roster(sessions, now: now, includeEnded: showEnded)
    }

    private var tokenCap: Int? {
        project.settings.caps.maxTokensPerAgent.map { max($0, 1) }
    }

    /// Computed once per body. The roster placeholder still reads the unsearched roster, so a query
    /// that matches nothing leaves an empty table and says so beside the field.
    private struct Layout {
        let roster: SessionRoster
        let rows: [AgentSession]
        let hiddenMatches: Int
        let ports: [AttributedPort]
        let shownPorts: [AttributedPort]
    }

    /// Reads the ports the sidebar panel's sweep already holds; narrowing them starts no sweep.
    private var layout: Layout {
        let roster = roster
        let ports = env.listeningPorts?.ports(inProject: project.id) ?? []
        let query = SearchQuery(query)
        guard !query.isEmpty else {
            return Layout(roster: roster, rows: roster.visible, hiddenMatches: 0, ports: ports, shownPorts: ports)
        }
        let titles = taskTitles
        let snapshot = status.value
        func matches(_ session: AgentSession) -> Bool {
            query.matches(StatusSearch.fields(
                of: session, taskTitle: session.taskId.flatMap { titles[$0] }, roleLabel: snapshot.roleLabel(session)
            ))
        }
        let visible = Set(roster.visible.map(\.sessionId))
        return Layout(
            roster: roster,
            rows: roster.visible.filter(matches),
            hiddenMatches: sessions.count { !visible.contains($0.sessionId) && matches($0) },
            ports: ports,
            shownPorts: ports.filter { query.matches(StatusSearch.fields(of: $0)) }
        )
    }

    var body: some View {
        let layout = layout
        VStack(spacing: 0) {
            SearchField(
                noun: .sessions, text: $query, shown: layout.rows.count, total: layout.roster.visible.count,
                note: StatusSearch.note(
                    hiddenEndedMatches: layout.hiddenMatches,
                    shownPorts: layout.shownPorts.count, totalPorts: layout.ports.count
                )
            )
            .padding(.horizontal)
            .padding(.vertical, 8)
            Divider()
            if let review = status.value.review {
                ReviewRoutingBanner(routing: review, typeReviews: status.value.typeReviews)
                Divider()
            }
            table(layout)
            StatusPortsSection(ports: layout.shownPorts)
            Divider()
            footer
        }
        .task(id: project.id) {
            await status.run(SessionStore(env.db).observeStatus(projectId: project.id), in: env.db.reader)
        }
        .task(id: project.id) {
            await tasks.run(TaskStore(env.db).observe(projectId: project.id), in: env.db.reader)
        }
        .task(id: project.id) {
            while !_Concurrency.Task.isCancelled {
                await reconcile()
                do {
                    try await _Concurrency.Task.sleep(for: .seconds(15))
                } catch {
                    break
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    run { try await env.supervisor.pauseAll(projectId: project.id) }
                } label: {
                    Label("Pause All", systemImage: "pause.circle")
                }
                .help("Stop every managed session in this project")
                Button {
                    _Concurrency.Task { await reconcile() }
                } label: {
                    Label("Reconcile", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("Join `claude agents` against the recorded sessions")
            }
        }
        .errorAlert($errorMessage)
    }

    private func table(_ layout: Layout) -> some View {
        let roster = layout.roster
        return Table(layout.rows) {
            TableColumn("ID") { session in
                Text(session.displayShortId)
                    .monospaced()
            }
            .width(min: 80, ideal: 90)

            TableColumn("Role") { session in
                Text(status.value.roleLabel(session))
                    .lineLimit(1)
                    .help(status.value.roleLabel(session))
            }
            .width(min: 80, ideal: 130)

            TableColumn("Task") { session in
                Text(session.taskId.flatMap { taskTitles[$0] } ?? "—")
                    .lineLimit(1)
            }

            TableColumn("State") { session in
                SessionStateLabel(state: session.state)
            }
            .width(min: 70, ideal: 90)

            TableColumn("Elapsed") { session in
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(session.elapsedText(at: context.date))
                        .monospacedDigit()
                }
            }
            .width(min: 70, ideal: 80)

            TableColumn("Spend") { session in
                VStack(alignment: .leading, spacing: 2) {
                    if let tokenCap {
                        Text("\(Format.cost(session.estCostUSD)) · \(Format.tokens(session.countedTokens)) / \(Format.tokens(tokenCap)) · \(Format.tokens(session.cacheRead)) cached")
                            .font(.caption)
                            .monospacedDigit()
                        ProgressView(value: Double(min(session.countedTokens, tokenCap)), total: Double(tokenCap))
                            .tint(session.countedTokens >= tokenCap ? .red : .accentColor)
                    } else {
                        Text("\(Format.cost(session.estCostUSD)) · \(Format.tokens(session.countedTokens)) · \(Format.tokens(session.cacheRead)) cached")
                            .font(.caption)
                            .monospacedDigit()
                    }
                }
            }
            .width(min: 140, ideal: 180)

            TableColumn("Last tool") { session in
                Text(session.lastTool ?? "—")
            }
            .width(min: 80, ideal: 110)

            TableColumn("Last activity") { session in
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(session.lastActivityDate.map(Format.relative) ?? "—")
                }
            }
            .width(min: 90, ideal: 110)

            TableColumn("Actions") { session in
                HStack(spacing: 4) {
                    SessionActionButtons(session: session, showsTitle: false)
                    if session.state.isActive {
                        Button("Stop") { run { try await env.supervisor.stop(sessionId: session.sessionId) } }
                    } else if session.state == .stopped || session.state == .failed {
                        Button("Resume") { run { try await env.supervisor.resume(sessionId: session.sessionId) } }
                    }
                }
                .controlSize(.small)
            }
            .width(min: 150, ideal: 170)
        }
        .overlay {
            if roster.visible.isEmpty {
                if roster.hiddenCount > 0 {
                    ContentUnavailableView(
                        "No Live Sessions",
                        systemImage: "cpu",
                        description: Text("\(roster.hiddenCount) ended \(roster.hiddenCount == 1 ? "session" : "sessions") hidden. Turn on Show ended to see them.")
                    )
                } else {
                    ContentUnavailableView(
                        "No Sessions",
                        systemImage: "cpu",
                        description: Text("Drag a task into Running to spawn a worker.")
                    )
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Label(serverPort.map { "Server port \($0)" } ?? "Server not listening", systemImage: "network")
            SleepFooterItem(guard: env.sleepGuard)
            if let lastError {
                Label(lastError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help(lastError)
            }
            Spacer()
            if roster.hiddenCount > 0 {
                Text("\(roster.hiddenCount) ended \(roster.hiddenCount == 1 ? "session" : "sessions") hidden")
                    .help("Ended sessions drop off the roster \(SessionVisibility.endedGraceDescription) after they finish. Nothing is deleted.")
            }
            Toggle("Show ended", isOn: $showEnded)
                .toggleStyle(.checkbox)
                .controlSize(.small)
            Text("\(sessions.filter { $0.state.isActive }.count) active · \(sessions.count) total")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func reconcile() async {
        now = .now
        await env.supervisor.reconcile(projectId: project.id)
        serverPort = env.supervisor.serverPort
        lastError = env.supervisor.lastError
    }

    private func run(_ operation: @escaping () async throws -> Void) {
        _Concurrency.Task {
            do {
                try await operation()
            } catch {
                errorMessage = errorText(error)
            }
        }
    }
}

#Preview("Status") {
    let preview = PreviewData.make()
    StatusView(project: preview.project)
        .environment(preview.environment)
        .frame(width: 1100, height: 500)
}

/// Says whether the Mac is being held awake, and by how much. The `.help` carries the part the
/// label cannot: idle sleep only, and a closed lid still sleeps. SPEC §8.3.
struct SleepFooterItem: View {
    @Bindable var `guard`: SleepGuard

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: `guard`.isHolding ? "cup.and.saucer.fill" : "powersleep")
                .foregroundStyle(`guard`.isHolding ? .primary : .secondary)
            Text(`guard`.footerLabel)
            Toggle("Keep awake", isOn: $guard.isEnabled)
                .toggleStyle(.checkbox)
                .controlSize(.small)
        }
        .help(`guard`.footerHelp)
    }
}

/// Under agent review, where the Default row sends this project's finished tasks, or why they go to a
/// person instead, and the type rows that route differently. SPEC §10.
struct ReviewRoutingBanner: View {
    let routing: ReviewRouting
    var typeReviews: [StatusSnapshot.TypeReview] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            defaultRow
            if !typeReviews.isEmpty {
                Text(typeReviews.map { "\($0.type.label): \(Self.shortLabel($0.routing))" }.joined(separator: " · "))
                    .lineLimit(2)
                    .padding(.leading, 22)
                    .help(typeReviews.compactMap(Self.reason).joined(separator: "\n"))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private static func shortLabel(_ routing: ReviewRouting) -> String {
        switch routing {
        case .agentReview(_, let name): return name
        case .humanReview: return "a person"
        case .autoAccept: return "no review"
        }
    }

    private static func reason(_ review: StatusSnapshot.TypeReview) -> String? {
        guard case .humanReview(let reason?) = review.routing else { return nil }
        return "\(review.type.label): \(reason)"
    }

    private var defaultRow: some View {
        HStack(spacing: 6) {
            switch routing {
            case .agentReview(_, let name):
                Image(systemName: "checkmark.seal")
                Text("Agent review: \(name) reviews finished tasks")
            case .humanReview(let reason):
                Image(systemName: "person.fill.questionmark")
                    .foregroundStyle(.orange)
                Text(reason ?? "Agent review: finished tasks go to a person")
                    .lineLimit(2)
                    .help(reason ?? "")
            case .autoAccept:
                Image(systemName: "checkmark.circle")
                Text("Agent review: finished tasks are accepted without review")
            }
            Spacer()
        }
    }
}

struct SessionStateLabel: View {
    let state: SessionState

    var body: some View {
        Text(state.label)
            .foregroundStyle(state.color)
            .fontWeight(.medium)
            .help(state.help ?? "")
    }
}
