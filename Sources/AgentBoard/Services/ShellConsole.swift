import AgentBoardCore
import AgentBoardRuntime
import AppKit
import Foundation
import Observation
import SwiftTerm

/// One plain login shell per project, rooted at the project's repo and alive for as long as the app.
///
/// It is not an agent session: no grant is issued for it, no session config is written for it, and
/// its environment goes through `ChildEnvironment.forHumanShell`, so nothing running in it holds
/// the board authority a worker or orchestrator session holds.
@MainActor
@Observable
final class ShellConsole {
    enum State: Equatable {
        case idle
        case starting
        case running
        /// The shell ended and nothing restarted it. `restart()` is the way back.
        case exited(Int32?)
    }

    static let hangUpGrace: Duration = .seconds(2)

    let projectId: String
    private(set) var state: State = .idle
    private(set) var lastError: String?
    /// The shell the last start launched, so the UI can name it and a test can check it.
    private(set) var shellPath: String?

    @ObservationIgnored let terminal: LocalProcessTerminalView
    @ObservationIgnored private let projects: ProjectStore
    @ObservationIgnored private let baseEnvironment: [String: String]
    @ObservationIgnored private let processObserver = ProcessObserver()
    @ObservationIgnored private var restartAfterExit = false

    init(
        projectId: String,
        db: AppDatabase,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.projectId = projectId
        projects = ProjectStore(db)
        self.baseEnvironment = baseEnvironment
        terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        terminal.nativeForegroundColor = .white
        terminal.nativeBackgroundColor = NSColor(calibratedRed: 0x1e / 255, green: 0x1e / 255, blue: 0x2e / 255, alpha: 1)
        terminal.caretColor = .systemGreen
        terminal.processDelegate = processObserver
        processObserver.console = self
    }

    var isProcessRunning: Bool {
        terminal.process.running
    }

    /// The running shell's pid, for anything that has to recognise a process this console started.
    var shellPID: pid_t? {
        guard isProcessRunning else { return nil }
        let pid = terminal.process.shellPid
        return pid > 0 ? pid : nil
    }

    /// Exactly what `launch()` hands the child, so a test asserting on it is asserting on the shell.
    func childEnvironment() -> [String] {
        ChildEnvironment.forHumanShell(baseEnvironment)
    }

    // MARK: - Lifecycle

    func start() {
        guard !isProcessRunning else { return }
        state = .starting
        lastError = nil
        do {
            try launch()
            state = .running
        } catch {
            lastError = errorText(error)
            state = .idle
        }
    }

    func restart() {
        if isProcessRunning {
            restartAfterExit = true
            hangUp()
        } else {
            start()
        }
    }

    func stop() {
        restartAfterExit = false
        hangUp()
    }

    /// SwiftTerm's `terminate()` sends SIGTERM, which an interactive shell ignores, so it would sit
    /// there. SIGHUP to the shell's process group is what a closing terminal window sends: the shell
    /// exits, running its own traps and hanging up its jobs. SIGKILL follows if it is still there,
    /// so `stop()` means stopped.
    private func hangUp() {
        let pid = terminal.process.shellPid
        guard isProcessRunning, pid > 0 else { return }
        kill(-pid, SIGHUP)
        _Concurrency.Task { @MainActor [weak self] in
            try? await _Concurrency.Task.sleep(for: Self.hangUpGrace)
            guard let self, self.isProcessRunning, self.terminal.process.shellPid == pid else { return }
            kill(-pid, SIGKILL)
        }
    }

    private func launch() throws {
        guard let project = try projects.get(projectId) else {
            throw SupervisorError.projectNotFound(projectId)
        }
        let shell = LoginShell.path(baseEnvironment)
        shellPath = shell
        terminal.startProcess(
            executable: shell,
            args: [],
            environment: childEnvironment(),
            execName: LoginShell.argv0(forPath: shell),
            currentDirectory: project.repoPath
        )
    }

    /// The human typed `exit`, or a command killed the shell. Nothing respawns it: a silent restart
    /// would make `exit` look broken and would hide a shell that dies on every start. The state
    /// carries the code so the UI can say so and offer `restart()`.
    private func processExited(code: Int32?) {
        state = .exited(code.map(Self.exitCode(fromWaitStatus:)))
        if restartAfterExit {
            restartAfterExit = false
            start()
        }
    }

    static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        WaitStatus.exitCode(fromWaitStatus: status)
    }

    private final class ProcessObserver: NSObject, LocalProcessTerminalViewDelegate {
        weak var console: ShellConsole?

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            _Concurrency.Task { @MainActor [weak console] in
                console?.processExited(code: exitCode)
            }
        }
    }
}
