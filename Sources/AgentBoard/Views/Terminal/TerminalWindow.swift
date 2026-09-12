import AgentBoardCore
import AgentBoardRuntime
import AppKit
import SwiftTerm
import SwiftUI

struct TerminalWindow: View {
    let sessionId: String

    @Environment(AppEnvironment.self) private var env
    @State private var session: AgentSession?
    @State private var taskTitle: String?
    @State private var command: (executable: String, arguments: [String])?
    @State private var loaded = false
    @State private var exitCode: Int32?

    private var title: String {
        let shortId = session?.displayShortId ?? String(sessionId.prefix(8))
        return "attach \(shortId) — \(taskTitle ?? "no task")"
    }

    var body: some View {
        Group {
            if !loaded {
                ProgressView()
            } else if let session, let command {
                VStack(spacing: 0) {
                    TerminalHostView(
                        executable: command.executable,
                        arguments: command.arguments,
                        currentDirectory: session.cwd
                    ) { code in
                        exitCode = code ?? -1
                    }
                    if let exitCode {
                        Text("attach exited with code \(exitCode). The background session is unaffected.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(6)
                            .frame(maxWidth: .infinity)
                            .background(.bar)
                    }
                }
            } else {
                ContentUnavailableView(
                    "Session not attachable",
                    systemImage: "terminal.fill",
                    description: Text(session == nil
                        ? "No session with id \(sessionId) is recorded."
                        : "The supervisor has no attach command for this session.")
                )
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .navigationTitle(title)
        .task(id: sessionId) {
            session = try? SessionStore(env.db).get(sessionId)
            if let taskId = session?.taskId {
                taskTitle = try? TaskStore(env.db).get(taskId)?.title
            }
            command = env.supervisor.attachCommand(sessionId: sessionId)
            loaded = true
        }
    }
}

struct TerminalHostView: NSViewRepresentable {
    let executable: String
    let arguments: [String]
    let currentDirectory: String
    let onExit: @MainActor (Int32?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onExit: onExit)
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        terminal.nativeForegroundColor = .white
        terminal.nativeBackgroundColor = NSColor(calibratedRed: 0x1e / 255, green: 0x1e / 255, blue: 0x2e / 255, alpha: 1)
        terminal.caretColor = .systemGreen
        terminal.processDelegate = context.coordinator
        context.coordinator.terminal = terminal
        terminal.startProcess(
            executable: executable,
            args: arguments,
            environment: Self.childEnvironment(),
            execName: nil,
            currentDirectory: currentDirectory
        )
        DispatchQueue.main.async {
            terminal.window?.makeFirstResponder(terminal)
        }
        return terminal
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        coordinator.terminate()
    }

    static func childEnvironment() -> [String] {
        ChildEnvironment.forTerminal()
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        weak var terminal: LocalProcessTerminalView?
        private let onExit: @MainActor (Int32?) -> Void
        private var finished = false

        init(onExit: @escaping @MainActor (Int32?) -> Void) {
            self.onExit = onExit
        }

        func terminate() {
            guard !finished, let terminal, terminal.process.running else { return }
            finished = true
            terminal.terminate()
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            guard !finished else { return }
            finished = true
            let onExit = onExit
            _Concurrency.Task { @MainActor in
                onExit(exitCode)
            }
        }
    }
}
