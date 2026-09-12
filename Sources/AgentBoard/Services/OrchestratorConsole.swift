import AgentBoardCore
import AgentBoardRuntime
import AppKit
import Foundation
import Observation
import SwiftTerm

/// Every byte the user types reaches the child through `send(source:data:)`; the console's own
/// notice goes through the same path, so it flags itself to keep the keystroke clock honest.
final class OrchestratorTerminalView: LocalProcessTerminalView {
    private(set) var lastUserInputAt: Date?
    var isInjecting = false

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if !isInjecting {
            lastUserInputAt = Date()
        }
        super.send(source: source, data: data)
    }
}

/// One per project; owns the orchestrator PTY and is the only place that writes into it (SPEC §9.1).
@MainActor
@Observable
final class OrchestratorConsole {
    enum State: Equatable {
        case idle
        case starting
        case running
        case exited(Int32?)
    }

    static let noticeQuietInterval: TimeInterval = 10

    let projectId: String
    private(set) var state: State = .idle
    private(set) var sessionId: String?
    private(set) var lastError: String?
    private(set) var lastNoticeAt: Date?

    @ObservationIgnored let terminal: OrchestratorTerminalView
    @ObservationIgnored private let projects: ProjectStore
    @ObservationIgnored private let sessions: SessionStore
    @ObservationIgnored private let grants: TokenGrantStore
    @ObservationIgnored private let reports: ReportStore
    @ObservationIgnored private let sessionConfigDir: URL
    @ObservationIgnored private let currentPort: @MainActor () -> Int?
    @ObservationIgnored private let processObserver = ProcessObserver()
    @ObservationIgnored private var lastAnnouncedReportId: Int64 = 0
    @ObservationIgnored private var lastStopAt: Date?
    @ObservationIgnored private var restartAfterExit = false

    init(projectId: String, db: AppDatabase, sessionConfigDir: URL, currentPort: @escaping @MainActor () -> Int?) {
        self.projectId = projectId
        projects = ProjectStore(db)
        sessions = SessionStore(db)
        grants = TokenGrantStore(db)
        reports = ReportStore(db)
        self.sessionConfigDir = sessionConfigDir
        self.currentPort = currentPort
        terminal = OrchestratorTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        terminal.nativeForegroundColor = .white
        terminal.nativeBackgroundColor = NSColor(calibratedRed: 0x1e / 255, green: 0x1e / 255, blue: 0x2e / 255, alpha: 1)
        terminal.caretColor = .systemGreen
        terminal.processDelegate = processObserver
        processObserver.console = self
    }

    var isProcessRunning: Bool {
        terminal.process.running
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
            terminal.terminate()
        } else {
            start()
        }
    }

    func stop() {
        restartAfterExit = false
        guard isProcessRunning else { return }
        terminal.terminate()
        if let sessionId {
            try? sessions.setState(sessionId, .stopped, endedAt: .nowMillis)
        }
    }

    private func launch() throws {
        guard let project = try projects.get(projectId) else {
            throw SupervisorError.projectNotFound(projectId)
        }
        guard let port = currentPort() else { throw SupervisorError.serverNotRunning }

        let sessionId: String
        if let pinned = project.orchSessionId, !pinned.isEmpty {
            sessionId = pinned
        } else {
            sessionId = UUID().uuidString.lowercased()
            try projects.setOrchestratorSession(project.id, sessionId: sessionId)
        }
        self.sessionId = sessionId

        if try sessions.get(sessionId) == nil {
            try sessions.insert(AgentSession(
                sessionId: sessionId,
                projectId: project.id,
                taskId: nil,
                role: .orchestrator,
                cwd: project.repoPath,
                state: .starting
            ))
        } else {
            try sessions.markResumed(sessionId)
            try sessions.setState(sessionId, .starting)
        }

        try grants.revokeAll(sessionId: sessionId)
        let grant = try grants.issue(projectId: project.id, scope: .orchestrator, taskId: nil)
        try grants.bind(token: grant.token, sessionId: sessionId)

        let configFiles = try SessionConfigWriter.write(
            configDir: sessionConfigDir,
            configId: "orchestrator-\(project.id)",
            port: port,
            token: grant.token,
            autoModeJSON: nil,
            extraMcpServers: nil
        )

        let command = InteractiveSessionCommand(
            sessionId: sessionId,
            cwd: URL(fileURLWithPath: project.repoPath),
            configFiles: configFiles,
            appendSystemPrompt: OrchestratorPrompt.systemPrompt(project: project),
            model: project.settings.defaultModel,
            strictMcpConfig: false
        )
        lastStopAt = nil
        terminal.startProcess(
            executable: command.executable,
            args: command.arguments(),
            environment: TerminalHostView.childEnvironment(),
            execName: nil,
            currentDirectory: project.repoPath
        )
    }

    private func processExited(code: Int32?) {
        state = .exited(code)
        if let sessionId, let row = try? sessions.get(sessionId), row.state.isActive {
            try? sessions.setState(sessionId, .stopped, endedAt: .nowMillis)
        }
        if restartAfterExit {
            restartAfterExit = false
            start()
        }
    }

    // MARK: - Report notice (SPEC §9.1)

    func turnEnded() {
        lastStopAt = Date()
        maybeNotice(turnEnded: true)
    }

    func reportsChanged() {
        maybeNotice(turnEnded: false)
    }

    func nudge() {
        guard isProcessRunning, let pending = try? pendingReports(), pending.count > 0 else { return }
        sendNotice(count: pending.count, maxId: pending.maxId)
    }

    private func maybeNotice(turnEnded: Bool) {
        guard isProcessRunning, let pending = try? pendingReports(), pending.count > 0 else { return }
        guard pending.maxId > lastAnnouncedReportId else { return }
        if !turnEnded {
            guard let lastStopAt else { return }
            if let typed = terminal.lastUserInputAt {
                guard typed < lastStopAt, Date().timeIntervalSince(typed) >= Self.noticeQuietInterval else { return }
            }
        }
        sendNotice(count: pending.count, maxId: pending.maxId)
    }

    private func pendingReports() throws -> (count: Int, maxId: Int64) {
        let unconsumed = try reports.unconsumed(projectId: projectId)
        return (unconsumed.count, unconsumed.compactMap(\.id).max() ?? 0)
    }

    private func sendNotice(count: Int, maxId: Int64) {
        terminal.isInjecting = true
        terminal.send(txt: "[agent-board] \(count) worker reports pending. Call list_reports.\r")
        terminal.isInjecting = false
        lastAnnouncedReportId = max(lastAnnouncedReportId, maxId)
        lastNoticeAt = Date()
    }

    private final class ProcessObserver: NSObject, LocalProcessTerminalViewDelegate {
        weak var console: OrchestratorConsole?

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
