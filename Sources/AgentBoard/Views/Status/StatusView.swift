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

    var body: some View {
        VStack(spacing: 0) {
            if let review = status.value.review {
                ReviewRoutingBanner(routing: review)
                Divider()
            }
            table
            StatusPortsSection(project: project)
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

    private var table: some View {
        Table(roster.visible) {
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

/// Under agent review, which rostered agent this project's finished tasks go to, or why they go to a
/// person instead. SPEC §10.
struct ReviewRoutingBanner: View {
    let routing: ReviewRouting

    var body: some View {
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
                EmptyView()
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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
