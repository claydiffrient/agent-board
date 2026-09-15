import AgentBoardCore
import AgentBoardRuntime
import AppKit
import Foundation
import Observation
import SwiftUI

/// Whether a session's recorded worktree can host a shell right now.
enum WorktreeShellAvailability: Equatable {
    case ready(path: String)
    case sessionUnknown(sessionId: String)
    case noWorktree(shortId: String)
    case missing(path: String)

    /// The recorded `worktree_path` is the only source for the directory; nothing is composed from a
    /// base, because task 36bf1b10 moved the default root and older rows still hold the old one.
    static func resolve(
        sessionId: String,
        session: AgentSession?,
        directoryExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> WorktreeShellAvailability {
        guard let session else { return .sessionUnknown(sessionId: sessionId) }
        guard let path = session.worktreePath, !path.isEmpty else {
            return .noWorktree(shortId: session.displayShortId)
        }
        return directoryExists(path) ? .ready(path: path) : .missing(path: path)
    }

    var path: String? {
        switch self {
        case .ready(let path), .missing(let path): path
        case .sessionUnknown, .noWorktree: nil
        }
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .ready: "Worktree shell"
        case .sessionUnknown: "Session not recorded"
        case .noWorktree: "No worktree"
        case .missing: "Worktree is gone"
        }
    }

    var message: String {
        switch self {
        case .ready(let path):
            "A plain shell in \(path)."
        case .sessionUnknown(let sessionId):
            "No session with id \(sessionId) is on the board, so there is no worktree to open."
        case .noWorktree(let shortId):
            "Session \(shortId) recorded no worktree — it ran in the project's own checkout. The project's Terminal screen opens a shell there."
        case .missing(let path):
            "Agent Board recorded this session's worktree at \(path), and nothing is there now. Accepting or discarding the task removes it."
        }
    }

    var symbol: String {
        switch self {
        case .ready: "apple.terminal"
        case .sessionUnknown: "questionmark.circle"
        case .noWorktree: "folder.badge.questionmark"
        case .missing: "folder.badge.minus"
        }
    }

    /// What a session row can decide without stat-ing the disk on every redraw. The window does the
    /// existence check at open time, when it is fresh.
    static func canOpen(_ session: AgentSession) -> Bool {
        session.worktreePath?.isEmpty == false
    }

    static func buttonHelp(_ session: AgentSession) -> String {
        guard let path = session.worktreePath, !path.isEmpty else {
            return "This session has no worktree — it ran in the project's own checkout."
        }
        return "Open a plain shell in \(path)"
    }
}

/// A human's shell in a worktree: the user's login shell, the directory the session recorded, and
/// none of the board authority an agent session carries.
struct WorktreeShellCommand: Equatable {
    let executable: String
    let execName: String
    let directory: String
    let environment: [String]

    static func make(
        directory: String,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> WorktreeShellCommand {
        let shell = LoginShell.path(base)
        return WorktreeShellCommand(
            executable: shell,
            execName: LoginShell.argv0(forPath: shell),
            directory: directory,
            environment: ChildEnvironment.forHumanShell(base)
        )
    }
}

/// Watches the worktree directory, because the shell's cwd can be reaped underneath it: accepting a
/// task removes every attempt's worktree, and a shell sitting on a deleted inode fails confusingly.
@MainActor
@Observable
final class WorktreeWatch {
    let path: String
    private(set) var isPresent: Bool

    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private let exists: (String) -> Bool

    init(
        path: String,
        interval: Duration = .seconds(2),
        exists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.path = path
        self.interval = interval
        self.exists = exists
        isPresent = exists(path)
    }

    func check() {
        isPresent = exists(path)
    }

    func run() async {
        while !_Concurrency.Task.isCancelled {
            check()
            do {
                try await _Concurrency.Task.sleep(for: interval)
            } catch {
                break
            }
        }
    }
}

/// One window per session, so reading `git log` in a worker's worktree survives navigating the board
/// away from the project — and dies with the worktree rather than outliving it on a screen the human
/// returns to for ordinary repo work.
struct WorktreeShellWindow: View {
    let sessionId: String

    @Environment(AppEnvironment.self) private var env
    @State private var availability: WorktreeShellAvailability?
    @State private var session: AgentSession?
    @State private var taskTitle: String?
    @State private var watch: WorktreeWatch?
    @State private var exitCode: Int32?

    private var title: String {
        let shortId = session?.displayShortId ?? String(sessionId.prefix(8))
        return "shell \(shortId) — \(taskTitle ?? "no task")"
    }

    var body: some View {
        Group {
            if let availability, case .ready(let path) = availability {
                shell(at: path)
            } else if let availability {
                ContentUnavailableView(
                    availability.title,
                    systemImage: availability.symbol,
                    description: Text(availability.message)
                )
            } else {
                ProgressView()
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .navigationTitle(title)
        .task(id: sessionId) {
            load()
            guard case .ready(let path)? = availability else { return }
            let watch = WorktreeWatch(path: path)
            self.watch = watch
            await watch.run()
        }
    }

    private func shell(at path: String) -> some View {
        let command = WorktreeShellCommand.make(directory: path)
        return VStack(spacing: 0) {
            if watch?.isPresent == false {
                Label(
                    "\(path) has been removed. This shell's working directory no longer exists; `cd` somewhere else or close the window.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.red.opacity(0.25))
            }
            TerminalHostView(
                executable: command.executable,
                arguments: [],
                currentDirectory: command.directory,
                environment: command.environment,
                execName: command.execName
            ) { code in
                exitCode = code.map(ShellConsole.exitCode(fromWaitStatus:)) ?? -1
            }
            if let exitCode {
                Text("Shell exited with code \(exitCode). The agent session is unaffected; close this window to be rid of it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
        }
    }

    private func load() {
        let session = try? SessionStore(env.db).get(sessionId)
        self.session = session
        if let taskId = session?.taskId {
            taskTitle = try? TaskStore(env.db).get(taskId)?.title
        }
        availability = .resolve(sessionId: sessionId, session: session)
    }
}
