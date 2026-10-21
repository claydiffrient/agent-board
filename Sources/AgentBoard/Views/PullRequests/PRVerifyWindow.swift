import AgentBoardCore
import AgentBoardRuntime
import Foundation
import SwiftUI

enum PRVerifyScene {
    static let id = "pr-verify"
}

/// Walk me through it (SPEC §13.4): the project's `verifyCommand`, `{url}` filled in, run by the
/// user's login shell in the project's checkout with none of an agent session's board authority.
struct PRVerifyCommand: Equatable {
    let executable: String
    let execName: String
    let arguments: [String]
    let directory: String
    let environment: [String]

    static func make(
        watch: PRWatch, project: Project, base: [String: String] = ProcessInfo.processInfo.environment
    ) -> PRVerifyCommand? {
        guard let command = project.settings.prFollowThrough.verifyCommand(for: watch.url) else { return nil }
        let shell = LoginShell.path(base)
        return PRVerifyCommand(
            executable: shell,
            execName: LoginShell.argv0(forPath: shell),
            arguments: ["-c", command],
            directory: project.repoPath,
            environment: ChildEnvironment.forHumanShell(base)
        )
    }
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
                        execName: command.execName
                    ) { code in
                        exitCode = code.map(ShellConsole.exitCode(fromWaitStatus:)) ?? -1
                    }
                    if let exitCode {
                        Text("The verify command exited with code \(exitCode). Close this window when you are done with its output.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(6)
                            .frame(maxWidth: .infinity)
                            .background(.bar)
                    }
                }
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
            let watch = try? PRWatchStore(env.db).get(watchId)
            self.watch = watch
            if let watch, let project = try? ProjectStore(env.db).get(watch.projectId) {
                command = PRVerifyCommand.make(watch: watch, project: project)
            }
            loaded = true
        }
    }
}
