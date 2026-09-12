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
    /// Resolves the approval; a spawn approval then runs the spawn path for its task.
    func approve(approvalId: String) async throws
    func deny(approvalId: String, reason: String?) async throws
    func promote(taskId: String) async throws
    /// Queues the human integration approval for the epic. Creates nothing else.
    func requestIntegration(epicId: String) async throws
    /// Opens the prefilled compare page for the epic branch; never creates the PR itself.
    @discardableResult
    func openPullRequest(epicId: String) async throws -> PullRequestOutcome
}
