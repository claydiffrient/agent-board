import Foundation

/// A rostered reviewer's checkout, read at its spawn and again at its verdict (SPEC §5.1). The verdict
/// is refused when the reviewer changed the branch or a tracked file, whatever the deny list missed.
public enum ReviewCheckout {
    public static func head(in directory: URL) throws -> String {
        try git(["rev-parse", "HEAD"], in: directory).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Why the verdict must be refused, or nil when HEAD is still `spawnHead` and no tracked file
    /// differs from it. Untracked files are ignored, so build and test output does not count.
    public static func change(since spawnHead: String, in directory: URL) throws -> String? {
        let now = try head(in: directory)
        if now != spawnHead {
            return "The branch HEAD moved from \(spawnHead.prefix(12)) to \(now.prefix(12)) during the review."
        }
        let status = try git(["status", "--porcelain", "--untracked-files=no"], in: directory)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard status.isEmpty else {
            return "Tracked files changed during the review:\n\(status)"
        }
        return nil
    }

    private static func git(_ args: [String], in directory: URL) throws -> String {
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        let result = try ProcessRunner.run(
            executable: URL(fileURLWithPath: WorktreeManager.gitPath), arguments: args, cwd: directory,
            environment: env
        )
        guard result.status == 0 else {
            throw AgentRuntimeError("git \(args.joined(separator: " ")) exited \(result.status): \(result.stderr)")
        }
        return result.stdout
    }
}
