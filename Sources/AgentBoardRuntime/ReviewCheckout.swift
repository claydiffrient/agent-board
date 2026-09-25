import CryptoKit
import Foundation

/// A rostered reviewer's checkout, read at its spawn and again at its verdict (SPEC §5.1). The verdict
/// is refused when the reviewer changed the branch or a tracked file, whatever the deny list missed.
public enum ReviewCheckout {
    /// What the reviewer found, stored in `agent_session.review_head`: the HEAD, then a fingerprint of
    /// the uncommitted tracked changes when there were any. A bare SHA is a clean tree.
    public static func baseline(in directory: URL) throws -> String {
        let head = try head(in: directory)
        guard let dirt = try dirtFingerprint(in: directory) else { return head }
        return "\(head) \(dirt)"
    }

    private static func head(in directory: URL) throws -> String {
        try git(["rev-parse", "HEAD"], in: directory).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Why the verdict must be refused, or nil when HEAD and the uncommitted tracked changes are
    /// still what `baseline` recorded. Untracked files are ignored, so build and test output does not count.
    public static func change(since baseline: String, in directory: URL) throws -> String? {
        let parts = baseline.split(separator: " ", maxSplits: 1).map(String.init)
        let spawnHead = parts.first ?? baseline
        let spawnDirt = parts.count > 1 ? parts[1] : nil
        let now = try head(in: directory)
        if now != spawnHead {
            return "The branch HEAD moved from \(spawnHead.prefix(12)) to \(now.prefix(12)) during the review."
        }
        guard try dirtFingerprint(in: directory) != spawnDirt else { return nil }
        let status = try porcelain(in: directory)
        guard spawnDirt != nil else {
            return "Tracked files changed during the review:\n\(status)"
        }
        return "Tracked files changed during the review. The checkout already had uncommitted tracked changes "
            + "when the review started, which are not the reviewer's, but it no longer matches them:\n\(status)"
    }

    private static func dirtFingerprint(in directory: URL) throws -> String? {
        let status = try porcelain(in: directory)
        guard !status.isEmpty else { return nil }
        let diff = try git(["diff", "HEAD", "--binary", "--no-color", "--no-ext-diff"], in: directory)
        let digest = SHA256.hash(data: Data((status + "\0" + diff).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func porcelain(in directory: URL) throws -> String {
        try git(["status", "--porcelain", "--untracked-files=no"], in: directory)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
