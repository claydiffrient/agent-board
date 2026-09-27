import AgentBoardCore
import SwiftUI

/// The Coordinator's page (SPEC §10): its console beside the Requests, Plans and Sessions sidebar,
/// laid out as a project's Orchestrator screen is.
struct CoordinatorView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var console: OrchestratorConsole?
    @State private var unavailable: String?

    var body: some View {
        HSplitView {
            consolePane
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            CoordinatorSidebar()
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)
        }
        .navigationTitle("Coordinator")
        .task { await attach() }
    }

    @ViewBuilder
    private var consolePane: some View {
        if let console {
            VStack(spacing: 0) {
                OrchestratorHeader(console: console, noun: "Coordinator", stopAll: nil)
                Divider()
                OrchestratorTerminalHost(console: console)
            }
        } else {
            ContentUnavailableView(
                "Coordinator unavailable",
                systemImage: "terminal",
                description: Text(unavailable ?? "Preparing the Coordinator console…")
            )
        }
    }

    /// Started when the human opens the page, as a project's orchestrator is (SPEC §9).
    private func attach() async {
        let console: OrchestratorConsole
        do {
            console = try env.supervisor.coordinatorSessionConsole()
        } catch {
            unavailable = errorText(error)
            return
        }
        self.console = console
        guard console.state == .idle else { return }
        for _ in 0..<50 where env.supervisor.serverPort == nil {
            try? await _Concurrency.Task.sleep(for: .milliseconds(200))
            if _Concurrency.Task.isCancelled { return }
        }
        console.start()
    }
}

struct CoordinatorSidebar: View {
    @Environment(AppEnvironment.self) private var env
    @State private var ledger = Observed<[CoordinatorLedgerRow]>([])
    @State private var plans = Observed<[Note]>([])
    @State private var snapshot = Observed<CoordinatorSnapshot>(.empty)
    @State private var openPlanId: String?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section("Requests") {
                if ledger.value.isEmpty {
                    Text("The Coordinator has sent no requests.")
                        .foregroundStyle(.secondary)
                }
                ForEach(ledger.value) { row in
                    requestRow(row)
                }
            }
            Section("Plans") {
                if plans.value.isEmpty {
                    Text("No plans yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(plans.value) { note in
                    Button {
                        openPlanId = note.id
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note.title)
                                .fontWeight(.medium)
                                .lineLimit(2)
                            Text("updated \(Format.relative(note.updatedDate))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Section {
                if let active = snapshot.value.active {
                    sessionRow(active, isActive: true)
                }
                if snapshot.value.history.isEmpty {
                    Text("No earlier sessions.")
                        .foregroundStyle(.secondary)
                }
                ForEach(snapshot.value.history) { session in
                    Button {
                        run { try env.supervisor.resumeCoordinatorSession(sessionId: session.sessionId) }
                    } label: {
                        sessionRow(session, isActive: false)
                    }
                    .buttonStyle(.plain)
                    .help("Resume this session in place of the current one")
                }
            } header: {
                HStack {
                    Text("Sessions")
                    Spacer()
                    Button("New Session") {
                        run { try env.supervisor.newCoordinatorSession() }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("End the current session, which stays resumable below, and start a fresh one")
                }
            }
        }
        .listStyle(.sidebar)
        .task {
            await ledger.run(RequestStore(env.db).observeLedgerRows(), in: env.db.reader)
        }
        .task {
            await plans.run(NoteStore(env.db).observe(projectId: nil), in: env.db.reader)
        }
        .task {
            await snapshot.run(CoordinatorStore(env.db).observe(), in: env.db.reader)
        }
        .sheet(item: Binding(
            get: { openPlanId.map(PlanSelection.init) },
            set: { openPlanId = $0?.id }
        )) { plan in
            PlanSheet(noteId: plan.id)
                .environment(env)
        }
        .errorAlert($errorMessage)
    }

    private struct PlanSelection: Identifiable {
        let id: String
    }

    private func requestRow(_ row: CoordinatorLedgerRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(row.projectName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(row.state.title)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .foregroundStyle(row.state == .declined ? .orange : .secondary)
            }
            Text(row.summary)
                .font(.caption)
                .lineLimit(2)
            if let reply = row.latestReply {
                Text(reply)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            ForEach(row.epics) { epic in
                Button {
                    env.router.open(NotificationRoute(projectId: row.projectId, subject: .epic(epic.id)))
                } label: {
                    Label(epic.title, systemImage: "square.stack.3d.up")
                        .lineLimit(1)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Open \(row.projectName)'s Task Board at this epic")
            }
        }
        .padding(.vertical, 2)
    }

    private func sessionRow(_ session: AgentSession, isActive: Bool) -> some View {
        HStack(spacing: 6) {
            Text(session.displayShortId)
                .monospaced()
            Text(Format.relative(Date(timeIntervalSince1970: TimeInterval(session.startedAt) / 1000)))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if isActive {
                Text("Active")
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            Text(Format.cost(session.estCostUSD))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func run(_ body: () throws -> Void) {
        do { try body() } catch { errorMessage = errorText(error) }
    }
}

/// One of the Coordinator's plans, read-only: the Coordinator writes them through its note tools.
struct PlanSheet: View {
    let noteId: String

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var detail = Observed<NoteDetail?>(nil)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let detail = detail.value {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(detail.note.title)
                            .font(.title2)
                        Text("version \(detail.note.version) · updated \(Format.relative(detail.note.updatedDate))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(detail.sections, id: \.heading) { section in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(section.heading)
                                    .font(.headline)
                                Text(section.body)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
            } else {
                ContentUnavailableView("Plan not found", systemImage: "questionmark.folder")
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 560, minHeight: 480)
        .task(id: noteId) {
            await detail.run(NoteStore(env.db).observe(noteId: noteId), in: env.db.reader)
        }
    }
}
