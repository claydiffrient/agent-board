import AgentBoardCore
import AgentBoardRuntime
import Foundation
import SwiftUI

enum PRVerifyScene {
    static let id = "pr-verify"
}

/// Walk me through it (SPEC §13.4): the project's `verifyCommand`, `{url}` filled in, run by the
/// user's login shell in the project's checkout with none of an agent session's board authority. A
/// template naming `{mcp_config}` gets a verifier grant's config path there, never in the environment.
/// `-i` because a `-c` shell is otherwise non-interactive and skips `.zshrc`, where PATH edits live.
struct PRVerifyCommand: Equatable {
    let executable: String
    let execName: String
    let arguments: [String]
    let directory: String
    let environment: [String]
    let template: String
    let lease: VerifierLease?

    static func make(
        watch: PRWatch, project: Project, verifier: VerifierLaunch? = nil,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> PRVerifyCommand? {
        let settings = project.settings.prFollowThrough
        guard var command = settings.verifyCommand(for: watch.url) else { return nil }
        var lease: VerifierLease?
        if PRFollowThroughSettings.namesMCPConfig(command) {
            guard let verifier else { throw VerifierLaunch.ServerNotRunning() }
            let issued = try verifier.lease(projectId: watch.projectId, prWatchId: watch.id)
            lease = issued
            command = settings.verifyCommand(for: watch.url, mcpConfig: issued.configURL.path) ?? command
        }
        let shell = LoginShell.path(base)
        return PRVerifyCommand(
            executable: shell,
            execName: LoginShell.argv0(forPath: shell),
            arguments: ["-i", "-c", command],
            directory: project.repoPath,
            environment: ChildEnvironment.forHumanShell(base),
            template: settings.verifyCommand ?? "",
            lease: lease
        )
    }

    /// The `claude "…"` form for a template typed as a slash command, once the shell has failed to
    /// run its first word as a file (SPEC §13.4). The command itself is never rewritten.
    static func slashCommandHint(
        template: String, exitCode: Int32, elapsed: Duration,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String? {
        guard exitCode != 0, elapsed < .seconds(1),
              let claudeForm = PRFollowThroughSettings.claudeForm(ofSlashCommand: template),
              let first = template.split(whereSeparator: \.isWhitespace).first, !fileExists(String(first))
        else { return nil }
        return "\(first) is a slash command, which only runs inside Claude. Set the verify command to \(claudeForm) to run it there."
    }
}

/// Where a Walk me through it window gets its verifier grant from.
struct VerifierLaunch {
    struct ServerNotRunning: Error, CustomStringConvertible {
        var description: String { "The board server is not running, so the verify command cannot be given board tools." }
    }

    let db: AppDatabase
    let configDir: URL
    let port: Int

    func lease(projectId: String, prWatchId: String) throws -> VerifierLease {
        let grants = TokenGrantStore(db)
        let grant = try grants.issueVerifier(projectId: projectId, prWatchId: prWatchId)
        do {
            let url = try SessionConfigWriter.writeVerifierMCPConfig(configDir: configDir, port: port, token: grant.token)
            return VerifierLease(token: grant.token, configURL: url, grants: grants)
        } catch {
            try? grants.revoke(token: grant.token)
            throw error
        }
    }
}

/// One window's verifier grant and the config file naming it, released on the shell's exit or the
/// window's close, whichever comes first.
final class VerifierLease: Equatable {
    let token: String
    let configURL: URL
    private let grants: TokenGrantStore
    private var released = false

    init(token: String, configURL: URL, grants: TokenGrantStore) {
        self.token = token
        self.configURL = configURL
        self.grants = grants
    }

    func release() {
        guard !released else { return }
        released = true
        try? grants.revoke(token: token)
        try? FileManager.default.removeItem(at: configURL)
    }

    static func == (lhs: VerifierLease, rhs: VerifierLease) -> Bool { lhs === rhs }
}

/// One window per pull request, beside the Terminal and Worktree Shell windows, rather than typing
/// into the project's Terminal screen: that shell may be mid-command, and nothing writes into a
/// human's PTY on its behalf.
struct PRVerifyWindow: View {
    let watchId: String

    @Environment(AppEnvironment.self) private var env
    @State private var watch: PRWatch?
    @State private var command: PRVerifyCommand?
    @State private var loaded = false
    @State private var exitCode: Int32?
    @State private var startedAt: ContinuousClock.Instant?
    @State private var hint: String?
    @State private var failure: String?

    private var title: String {
        guard let watch else { return "verify" }
        return "verify \(watch.repoOwner)/\(watch.repoName) #\(watch.number)"
    }

    var body: some View {
        Group {
            if !loaded {
                ProgressView()
            } else if let command {
                VStack(spacing: 0) {
                    TerminalHostView(
                        executable: command.executable,
                        arguments: command.arguments,
                        currentDirectory: command.directory,
                        environment: command.environment,
                        execName: command.execName,
                        inventory: watch.map { (ProcessOwner(role: .humanShell, projectId: $0.projectId), env.terminalProcesses) }
                    ) { code in
                        command.lease?.release()
                        let exited = code.map(ShellConsole.exitCode(fromWaitStatus:)) ?? -1
                        exitCode = exited
                        hint = startedAt.flatMap {
                            PRVerifyCommand.slashCommandHint(
                                template: command.template, exitCode: exited, elapsed: .now - $0
                            )
                        }
                    }
                    if let exitCode {
                        VStack(spacing: 2) {
                            if let hint {
                                Text(hint)
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            Text("The verify command exited with code \(exitCode). Close this window when you are done with its output.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity)
                        .background(.bar)
                    }
                }
            } else if let failure {
                ContentUnavailableView(
                    "Could not start the verify command",
                    systemImage: "exclamationmark.triangle",
                    description: Text(failure)
                )
            } else {
                ContentUnavailableView(
                    "Nothing to run",
                    systemImage: "apple.terminal",
                    description: Text(watch == nil
                        ? "No watched pull request with id \(watchId) is recorded."
                        : "This project sets no verify command.")
                )
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .navigationTitle(title)
        .task(id: watchId) {
            await env.startup?.value
            let watch = try? PRWatchStore(env.db).get(watchId)
            self.watch = watch
            if let watch, let project = try? ProjectStore(env.db).get(watch.projectId) {
                let verifier = env.supervisor.serverPort.map {
                    VerifierLaunch(db: env.db, configDir: SessionConfigWriter.configDir(supportDir: Wiring.appSupportDir), port: $0)
                }
                do {
                    let made = try PRVerifyCommand.make(watch: watch, project: project, verifier: verifier)
                    if _Concurrency.Task.isCancelled {
                        made?.lease?.release()
                        return
                    }
                    command = made
                    startedAt = .now
                } catch {
                    failure = "\(error)"
                }
            }
            loaded = true
        }
        .onDisappear { command?.lease?.release() }
    }
}
