import Foundation
import AgentBoardCore

/// The UI's only entry point for anything that touches processes, git, or the network.
@MainActor
public protocol WorkerSupervising: AnyObject {
    var serverPort: Int? { get }
    var lastError: String? { get }

    func registerProject(repoPath: URL, name: String?, baseBranch: String?) async throws -> Project
    /// SPEC §3.1: worktree, memory symlink, config files, spawn, record session. Refuses on cap breach.
    func assign(taskId: String) async throws
    func stop(sessionId: String) async throws
    /// Rewrites the session's config files with the current port, then `claude --bg --resume`.
    func resume(sessionId: String) async throws
    func pauseAll(projectId: String) async throws
    /// Task → done, worktree removed (chaining the user's WorktreeRemove hook), branch kept.
    func accept(taskId: String) async throws
    func reopen(taskId: String) async throws
    /// Stops any active worker, removes the worktree (branch kept), deletes the task and its progress.
    func discard(taskId: String) async throws
    /// Joins `claude agents --json --all` against agent_session so dead sessions show as dead.
    func reconcile(projectId: String) async
    func attachCommand(sessionId: String) -> (executable: String, arguments: [String])?
    func worktreeDiffstat(taskId: String) async -> String?
}
