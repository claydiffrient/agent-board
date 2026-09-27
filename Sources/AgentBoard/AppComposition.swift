import AgentBoardCore
import AgentBoardRuntime
import AppKit
import Foundation

@MainActor
enum AppComposition {
    static func make() -> AppEnvironment {
        _ = LoginShellPath.shared
        let url = ProcessInfo.processInfo.environment["AGENTBOARD_DB"].map { URL(fileURLWithPath: $0) }
            ?? Wiring.appSupportDir.appendingPathComponent("agentboard.sqlite")
        do {
            let db = try AppDatabase.open(at: url, build: BuildIdentity(infoDictionary: Bundle.main.infoDictionary))
            let sleepGuard = SleepGuard()
            sleepGuard.releaseOnTermination()
            let supervisor = Wiring.makeSupervisor(db: db, sleepGuard: sleepGuard)
            let startup = _Concurrency.Task { await supervisor.start() }
            let ports = ListeningPortModel(
                db: db,
                boardServerPort: { [weak supervisor] in supervisor?.serverPort },
                shellConsolePIDs: { [weak supervisor] in supervisor?.shellConsolePIDs() ?? [:] }
            )
            _Concurrency.Task { await ports.run() }
            let environment = AppEnvironment(
                db: db, supervisor: supervisor, sleepGuard: sleepGuard, startup: startup,
                listeningPorts: ports
            )
            MacNotifier.shared.start(router: environment.router)
            return environment
        } catch let refusal as AppDatabaseError {
            switch refusal {
            case .writtenByNewerBuild: refuseNewerDatabase(refusal)
            case .backupFailed: refuseWithoutBackup(refusal)
            }
        } catch {
            fatalError("Agent Board could not open its database at \(url.path): \(error)")
        }
    }

    private static func refuseNewerDatabase(_ refusal: AppDatabaseError) -> Never {
        guard case let .writtenByNewerBuild(database, _, backup) = refusal else { exit(1) }
        let recovery = if let command = refusal.restoreCommand, let backup {
            """
            Install the newer build again, or restore the newest backup, \(backup.lastPathComponent), by hand before relaunching:

            \(command)

            Restoring discards everything the board recorded since that backup.
            """
        } else {
            "Install the newer build again. There is no backup in "
                + "\(database.deletingLastPathComponent().appendingPathComponent("backups").path) to restore."
        }
        quit(
            title: "This database was last used by a newer Agent Board",
            text: """
                \(refusal.localizedDescription) Agent Board did not open it and has changed nothing.

                \(recovery)
                """
        )
    }

    private static func refuseWithoutBackup(_ refusal: AppDatabaseError) -> Never {
        guard case let .backupFailed(database, backups, reason) = refusal else { exit(1) }
        quit(
            title: "Agent Board couldn't back up the board",
            text: """
                Agent Board didn't open the board because it couldn't take a safe backup of \(database.path) first:

                \(reason)

                Nothing was written to the database. Backups are kept in \(backups.path). Fix the problem above, such as a full disk, and relaunch.
                """
        )
    }

    /// Nothing has written to the database yet, and quitting here keeps it that way (SPEC §4.1).
    private static func quit(title: String, text: String) -> Never {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "Quit")
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        alert.runModal()
        exit(1)
    }
}

enum StubError: LocalizedError {
    case notWired

    var errorDescription: String? {
        "The worker supervisor is not wired up yet."
    }
}

@MainActor
final class StubSupervisor: WorkerSupervising {
    var serverPort: Int? { nil }
    var lastError: String? { nil }
    /// Every project the window has focused, in order. `MainWindow.select` is its only caller, so
    /// a recorded id is proof that a selection went through the sidebar's own funnel.
    private(set) var focusedProjects: [String?] = []

    func focusChanged(projectId: String?) { focusedProjects.append(projectId) }

    func registerProject(repoPath: URL, name: String?, baseBranch: String?) async throws -> Project {
        throw StubError.notWired
    }

    func assign(taskId: String) async throws { throw StubError.notWired }
    func waitForSetup() async {}
    func stop(sessionId: String) async throws { throw StubError.notWired }
    func resume(sessionId: String) async throws { throw StubError.notWired }
    func pauseAll(projectId: String) async throws { throw StubError.notWired }
    func accept(taskId: String) async throws { throw StubError.notWired }
    func reopen(taskId: String) async throws { throw StubError.notWired }
    func discard(taskId: String) async throws { throw StubError.notWired }
    func reconcile(projectId: String) async {}
    func attachCommand(sessionId: String) -> (executable: String, arguments: [String])? { nil }
    func worktreeDiffstat(taskId: String) async -> String? { nil }
    func worktreeDiffSummary(taskId: String) async -> DiffSummary? { nil }
    func orchestratorConsole(projectId: String) throws -> OrchestratorConsole { throw StubError.notWired }
    func shellConsole(projectId: String) throws -> ShellConsole { throw StubError.notWired }
    func coordinatorSessionConsole() throws -> OrchestratorConsole { throw StubError.notWired }
    func newCoordinatorSession() throws { throw StubError.notWired }
    func resumeCoordinatorSession(sessionId: String) throws { throw StubError.notWired }
    func approve(approvalId: String) async throws { throw StubError.notWired }
    func deny(approvalId: String, reason: String?) async throws { throw StubError.notWired }
    func promote(taskId: String) async throws { throw StubError.notWired }
    func requestIntegration(epicId: String) async throws { throw StubError.notWired }
    func epicClosurePlan(epicId: String, as closure: EpicClosure) throws -> EpicClosurePlan { throw StubError.notWired }
    func closeEpic(epicId: String, as closure: EpicClosure) async throws { throw StubError.notWired }
    func openPullRequest(epicId: String) async throws -> PullRequestOutcome { throw StubError.notWired }
    func requestShutdown(projectId: String, requestedBy: String, reason: String?) async throws -> ShutdownOrder {
        throw StubError.notWired
    }
    func cancelShutdown(projectId: String, by: String) async throws -> ShutdownOrder? { throw StubError.notWired }
    func isShuttingDown(projectId: String) -> Bool { false }
    func deliverShutdownOrder(projectId: String) async throws -> ShutdownProgress { throw StubError.notWired }
    func requestGlobalShutdown(requestedBy: String, reason: String?) async throws -> [ShutdownOrder] { throw StubError.notWired }
    func cancelGlobalShutdown(by: String) async throws -> [ShutdownOrder] { throw StubError.notWired }
    func stopOrchestratorConsoles() {}
    var shutdownProgress: [String: ShutdownProgress] { [:] }
}
