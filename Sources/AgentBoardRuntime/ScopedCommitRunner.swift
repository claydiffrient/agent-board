import AgentBoardCore
import Foundation

/// Commits a shared-checkout task's own paths, and nothing else in the tree.
///
/// Every co-resident agent's commit funnels through this one object, because the agents are
/// separate `claude --bg` processes but all of them reach git through the app's MCP server. Two
/// commits racing in one checkout would otherwise collide on `.git/index.lock`.
public actor ScopedCommitRunner: ScopedCommitting {
    public init() {}

    public func commit(_ request: ScopedCommitRequest) async throws -> ScopedCommitOutcome {
        let repo = URL(fileURLWithPath: request.repoPath, isDirectory: true)
        let manager = WorktreeManager(repoPath: repo, worktreeRoot: repo, attribution: .unattributable)
        guard !request.paths.isEmpty else { throw ScopedCommitError.noPathsHeld }

        let staged = try Self.committable(request.paths, manager: manager, repo: repo)
        guard !staged.isEmpty else { return .nothingToCommit(paths: request.paths) }

        // `-A` so a file the task deleted is recorded as a deletion; the pathspec is the task's own
        // claimed paths, so nothing a sibling is holding can be reached by it.
        try manager.gitChecked(["add", "-A", "--"] + staged, cwd: repo)

        // `git commit -- <paths>` is a partial commit: it takes the working-tree content of exactly
        // these paths and ignores everything else the index holds, which is what keeps a sibling's
        // in-progress edits — staged or not — out of this commit.
        let config = try manager.mergeConfig()
        let result = try manager.gitRaw(
            config + ["commit", "-q", "-m", request.message, "--"] + staged, cwd: repo
        )
        guard result.status == 0 else {
            let text = result.stdout + result.stderr
            if text.contains("nothing to commit") || text.contains("no changes added to commit") {
                return .nothingToCommit(paths: request.paths)
            }
            throw ScopedCommitError.git("git commit exited \(result.status): \(text)")
        }
        let sha = try manager.gitChecked(["rev-parse", "HEAD"], cwd: repo).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .committed(sha: sha, paths: staged)
    }

    /// Drops claimed paths git would refuse: a file that was locked by a write that never landed is
    /// neither on disk nor tracked, and `git add` fails the whole pathspec over one of those.
    private static func committable(_ paths: [String], manager: WorktreeManager, repo: URL) throws -> [String] {
        let tracked = Set(
            try manager.gitChecked(["ls-files", "--"] + paths, cwd: repo).stdout
                .split(separator: "\n").map(String.init)
        )
        return paths.filter { tracked.contains($0) || FileManager.default.fileExists(atPath: repo.appendingPathComponent($0).path) }
    }
}
