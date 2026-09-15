import AgentBoardCore
import AppKit
import SwiftTerm
import SwiftUI

struct TerminalScreenView: View {
    let project: Project

    @Environment(AppEnvironment.self) private var env
    @State private var console: ShellConsole?
    @State private var unavailable: String?

    var body: some View {
        Group {
            if let console {
                VStack(spacing: 0) {
                    TerminalScreenHeader(console: console, workingDirectory: project.repoPath)
                    Divider()
                    ShellTerminalHost(console: console)
                }
            } else {
                ContentUnavailableView(
                    "Terminal unavailable",
                    systemImage: "apple.terminal",
                    description: Text(unavailable ?? "Preparing the shell…")
                )
            }
        }
        .task(id: project.id) {
            attach()
        }
    }

    /// The supervisor memoizes the console per project, and the state guard keeps a second start
    /// off an already-running — or deliberately exited — shell. Both are needed: returning to the
    /// project rebuilds this view from scratch, so `attach()` runs again over the same console.
    private func attach() {
        let console: ShellConsole
        do {
            console = try env.supervisor.shellConsole(projectId: project.id)
        } catch {
            unavailable = errorText(error)
            return
        }
        self.console = console
        guard console.state == .idle else { return }
        console.start()
    }
}

private struct TerminalScreenHeader: View {
    let console: ShellConsole
    let workingDirectory: String

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(stateColor)
                .frame(width: 8, height: 8)
            Text(stateText)
                .fontWeight(.medium)
            Text(abbreviatedDirectory)
                .monospaced()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .help(workingDirectory)
            if let error = console.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help(error)
            }
            Spacer()
            Button(console.isProcessRunning ? "Restart" : "Start Again") { console.restart() }
                .help(console.isProcessRunning
                    ? "Hang up this shell and open a fresh one in the same directory"
                    : "Open a fresh shell in the same directory")
            Button("Stop") { console.stop() }
                .disabled(!console.isProcessRunning)
        }
        .controlSize(.small)
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var abbreviatedDirectory: String {
        (workingDirectory as NSString).abbreviatingWithTildeInPath
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
private struct ShellTerminalHost: NSViewRepresentable {
    let console: ShellConsole

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminal = console.terminal
        DispatchQueue.main.async {
            terminal.window?.makeFirstResponder(terminal)
        }
        return terminal
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
