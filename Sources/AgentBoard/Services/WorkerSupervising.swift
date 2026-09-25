import Foundation
import AgentBoardCore
import AgentBoardRuntime

/// The UI's only entry point for anything that touches processes, git, or the network.
@MainActor
protocol WorkerSupervising: AnyObject {
    var serverPort: Int? { get }
    var lastError: String? { get }

    func registerProject(repoPath: URL, name: String?, baseBranch: String?) async throws -> Project
    /// SPEC §3.1: worktree, memory symlink, config files, spawn, record session. Refuses on cap breach.
    func assign(taskId: String) async throws
    /// `assign` answers while the worktree is still being prepared; this waits for that half.
    func waitForSetup() async
    func stop(sessionId: String) async throws
    /// Rewrites the session's config files with the current port, then `claude --bg --resume`.
    func resume(sessionId: String) async throws
    func pauseAll(projectId: String) async throws
    /// Task → done, every attempt's worktree removed (chaining the user's WorktreeRemove hook),
    /// and the task branch deleted once it is merged into the base or epic branch.
    func accept(taskId: String) async throws
    func reopen(taskId: String) async throws
    /// Stops any active worker, removes every attempt's worktree, deletes the task and its progress.
    /// The branch survives unless it is already merged.
    func discard(taskId: String) async throws
    /// Joins `claude agents --json --all` against agent_session so dead sessions show as dead,
    /// then reaps worktrees under the project's root that no active session owns.
    func reconcile(projectId: String) async
    func attachCommand(sessionId: String) -> (executable: String, arguments: [String])?
    func worktreeDiffstat(taskId: String) async -> String?
    func worktreeDiffSummary(taskId: String) async -> DiffSummary?
    /// Creates the project's console on first call and keeps it alive; does not start the process.
    func orchestratorConsole(projectId: String) throws -> OrchestratorConsole
    /// Creates the project's plain shell on first call and keeps it alive; does not start the shell.
    func shellConsole(projectId: String) throws -> ShellConsole
    /// Resolves the approval; a spawn approval then runs the spawn path for its task.
    func approve(approvalId: String) async throws
    func deny(approvalId: String, reason: String?) async throws
    func promote(taskId: String) async throws
    /// Queues the human integration approval for the epic. Creates nothing else.
    func requestIntegration(epicId: String) async throws
    /// What closing the epic would do, for the confirmation to read before the human commits.
    func epicClosurePlan(epicId: String, as closure: EpicClosure) throws -> EpicClosurePlan
    /// Writes the terminal epic state and queues the `decision` report. Merges nothing, deletes no
    /// branch or worktree, and leaves every unfinished task where it is. Refused while a worker is
    /// running in the epic and for an epic that is already terminal.
    func closeEpic(epicId: String, as closure: EpicClosure) async throws
    /// Opens the prefilled compare page for the epic branch; never creates the PR itself.
    @discardableResult
    func openPullRequest(epicId: String) async throws -> PullRequestOutcome
    /// Raises the standing order that refuses every new worker. Stops nothing that is already running.
    @discardableResult
    func requestShutdown(projectId: String, requestedBy: String, reason: String?) async throws -> ShutdownOrder
    /// Nil when no order was outstanding.
    @discardableResult
    func cancelShutdown(projectId: String, by: String) async throws -> ShutdownOrder?
    func isShuttingDown(projectId: String) -> Bool
    /// Hands the outstanding order to every running worker and starts collecting acknowledgments.
    /// Stops nothing: a worker ends its own session by calling `acknowledge_shutdown`.
    @discardableResult
    func deliverShutdownOrder(projectId: String) async throws -> ShutdownProgress
    /// Raises an order on every project — including ones with no active session — and delivers
    /// them all, so no project can spawn into the gap while the others are being wound down.
    @discardableResult
    func requestGlobalShutdown(requestedBy: String, reason: String?) async throws -> [ShutdownOrder]
    /// Lifts the order on every project, attempting all of them before reporting any failure.
    @discardableResult
    func cancelGlobalShutdown(by: String) async throws -> [ShutdownOrder]
    /// Ends every orchestrator PTY this process owns, before the app terminates.
    func stopOrchestratorConsoles()
    /// Wind-down counts per project id, so the progress sheet observes rather than polls.
    var shutdownProgress: [String: ShutdownProgress] { get }
    /// The project the human has open, or nil for At a Glance. Attention banners for it are
    /// suppressed while Agent Board is frontmost.
    func focusChanged(projectId: String?)
    /// A report was queued outside the supervisor — the human's comment (SPEC §9.1) — so the
    /// orchestrator console is told now rather than on the next board event.
    func reportQueued(projectId: String) async
}

extension WorkerSupervising {
    func focusChanged(projectId: String?) {}
    func reportQueued(projectId: String) async {}
}
