import AgentBoardCore
import AppKit
import SwiftTerm
import SwiftUI

struct OrchestratorView: View {
    let project: Project

    @Environment(AppEnvironment.self) private var env
    @State private var console: OrchestratorConsole?
    @State private var unavailable: String?
    @State private var sessions = Observed<[AgentSession]>([])
    @State private var confirmingStopAll = false
    @State private var shutdown: ShutdownOrder?
    @State private var errorMessage: String?

    private var runningWorkers: Int {
        sessions.value.filter { $0.role == .worker && $0.state.isActive }.count
    }

    var body: some View {
        HSplitView {
            consolePane
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            ApprovalsSidebar(project: project)
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)
        }
        .task(id: project.id) {
            await attach()
        }
        .task(id: project.id) {
            await sessions.run(SessionStore(env.db).observe(projectId: project.id), in: env.db.reader)
        }
        .task(id: project.id) {
            shutdown = try? ShutdownOrderStore(env.db).outstanding(projectId: project.id)
        }
        .confirmationDialog(
            "Stop all work on \(project.name)?",
            isPresented: $confirmingStopAll,
            titleVisibility: .visible
        ) {
            Button("Stop All", role: .destructive) { stopAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(stopAllConfirmation)
        }
        .sheet(item: $shutdown) { order in
            ShutdownSheet(project: project, order: order, console: console)
                .environment(env)
        }
        .errorAlert($errorMessage)
    }

    private var stopAllConfirmation: String {
        let workers = runningWorkers == 1 ? "1 worker is running" : "\(runningWorkers) workers are running"
        return "\(workers). Each is told to commit its worktree and stop, and its unfinished task goes "
            + "back to ready with a resume note, so nothing is lost. No new worker is spawned until "
            + "you cancel the order."
    }

    private func stopAll() {
        _Concurrency.Task {
            do {
                let order = try await env.supervisor.requestShutdown(
                    projectId: project.id, requestedBy: "human", reason: nil
                )
                shutdown = order
                try await env.supervisor.deliverShutdownOrder(projectId: project.id)
            } catch {
                errorMessage = errorText(error)
            }
        }
    }

    @ViewBuilder
    private var consolePane: some View {
        if let console {
            VStack(spacing: 0) {
                OrchestratorHeader(console: console, stopAll: { confirmingStopAll = true })
                Divider()
                OrchestratorTerminalHost(console: console)
            }
        } else {
            ContentUnavailableView(
                "Orchestrator unavailable",
                systemImage: "terminal",
                description: Text(unavailable ?? "Preparing the orchestrator console…")
            )
        }
    }

    /// SPEC §9: resumed when the human opens the project, after the server has a port to hand the session.
    private func attach() async {
        let console: OrchestratorConsole
        do {
            console = try env.supervisor.orchestratorConsole(projectId: project.id)
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

private struct OrchestratorHeader: View {
    let console: OrchestratorConsole
    let stopAll: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(stateColor)
                .frame(width: 8, height: 8)
            Text(stateText)
                .fontWeight(.medium)
            if let sessionId = console.sessionId {
                Text(sessionId.prefix(8))
                    .monospaced()
                    .foregroundStyle(.secondary)
                    .help(sessionId)
            }
            if let error = console.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help(error)
            }
            Spacer()
            if let at = console.lastNoticeAt {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text("Noticed \(Format.relative(at))")
                        .foregroundStyle(.secondary)
                }
            }
            Button("Nudge") { console.nudge() }
                .help("Tell the orchestrator about pending reports now")
                .disabled(!console.isProcessRunning)
            Button("Restart") { console.restart() }
                .help("Stop the orchestrator and resume the same session")
            Button("Stop") { console.stop() }
                .disabled(!console.isProcessRunning)
            Button("Stop All") { stopAll() }
                .help("Tell every worker to commit and stop, then quit")
        }
        .controlSize(.small)
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var stateText: String {
        switch console.state {
        case .idle: "Idle"
        case .starting: "Starting"
        case .running: "Running"
        case .exited(let code): code.map { "Exited (\($0))" } ?? "Exited"
        }
    }

    private var stateColor: SwiftUI.Color {
        switch console.state {
        case .idle: .secondary
        case .starting: .orange
        case .running: .green
        case .exited(let code): code == 0 ? .secondary : .red
        }
    }
}

/// Hosts the console's long-lived terminal view; the console owns it, so nothing is torn down here.
private struct OrchestratorTerminalHost: NSViewRepresentable {
    let console: OrchestratorConsole

    func makeNSView(context: Context) -> OrchestratorTerminalView {
        let terminal = console.terminal
        DispatchQueue.main.async {
            terminal.window?.makeFirstResponder(terminal)
        }
        return terminal
    }

    func updateNSView(_ nsView: OrchestratorTerminalView, context: Context) {}
}

#Preview("Orchestrator") {
    let preview = PreviewData.make()
    OrchestratorView(project: preview.project)
        .environment(preview.environment)
        .frame(width: 1200, height: 700)
}
