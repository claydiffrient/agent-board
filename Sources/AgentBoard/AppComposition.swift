import AgentBoardCore
import AgentBoardRuntime
import Foundation

@MainActor
enum AppComposition {
    static func make() -> AppEnvironment {
        let url = ProcessInfo.processInfo.environment["AGENTBOARD_DB"].map { URL(fileURLWithPath: $0) }
            ?? Wiring.appSupportDir.appendingPathComponent("agentboard.sqlite")
        do {
            let db = try AppDatabase.open(at: url)
            let supervisor = Wiring.makeSupervisor(db: db)
            _Concurrency.Task { await supervisor.start() }
            return AppEnvironment(db: db, supervisor: supervisor)
        } catch {
            fatalError("Agent Board could not open its database at \(url.path): \(error)")
        }
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
    func approve(approvalId: String) async throws { throw StubError.notWired }
    func deny(approvalId: String, reason: String?) async throws { throw StubError.notWired }
    func promote(taskId: String) async throws { throw StubError.notWired }
    func requestIntegration(epicId: String) async throws { throw StubError.notWired }
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
