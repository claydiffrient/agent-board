import AgentBoardCore
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

    /// Whether `git diff <base>...HEAD` has anything in it: what a reviewer would read.
    public static func hasDiff(against base: String, in directory: URL) throws -> Bool {
        let result = try ProcessRunner.run(
            executable: URL(fileURLWithPath: WorktreeManager.gitPath),
            arguments: ["diff", "--quiet", "\(base)...HEAD"], cwd: directory, environment: gitEnvironment
        )
        switch result.status {
        case 0: return false
        case 1: return true
        default: throw AgentRuntimeError("git diff --quiet \(base)...HEAD exited \(result.status): \(result.stderr)")
        }
    }

    /// Every path a reviewer's checkout differs in from `base`: the branch's commits since `base`, plus
    /// uncommitted and untracked files, which a reviewer in the same worktree loads too, plus gitignored
    /// review-rule files new or changed since `ignoredBaseline` (SPEC §5.1).
    /// `--no-renames` keeps a renamed-away file in the list under its old name.
    public static func changedFiles(
        against base: String, in directory: URL, ignoredBaseline: [String: String]
    ) throws -> [String] {
        let listings = [
            ["diff", "--name-only", "-z", "--no-renames", "\(base)...HEAD"],
            ["diff", "--name-only", "-z", "--no-renames", "HEAD"],
            ["ls-files", "-z", "--others", "--exclude-standard"],
        ]
        let ignored = try ignoredReviewRules(in: directory)
            .filter { ignoredBaseline[$0.key] != $0.value }.keys.sorted()
        return try unique(listings.flatMap { try nulSeparated(git($0, in: directory)) } + ignored)
    }

    /// Gitignored files Claude Code would load as review rules, by path, each with a SHA-256 of its
    /// content. Recorded at worktree setup, since setup itself may write some (SPEC §5.1).
    public static func ignoredReviewRules(in directory: URL) throws -> [String: String] {
        let output = try git([
            "ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--",
            ":(glob,icase)**/CLAUDE.md", ":(glob,icase)**/CLAUDE.local.md", ":(glob,icase)**/.claude/**",
            ":(icase).mcp.json",
        ], in: directory)
        let paths = ProtectedPaths.matching(nulSeparated(output))
        return Dictionary(paths.map { path in
            let data = try? Data(contentsOf: directory.appendingPathComponent(path))
            return (path, data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "unreadable")
        }, uniquingKeysWith: { first, _ in first })
    }

    /// The paths the given commits touched, for work committed on a shared branch (SPEC §5.1).
    public static func changedFiles(inCommits shas: [String], in directory: URL) throws -> [String] {
        try unique(shas.flatMap { sha in
            try nulSeparated(git(["show", "--name-only", "-z", "--no-renames", "--format=", sha], in: directory))
        })
    }

    private static func nulSeparated(_ output: String) -> [String] {
        output.split(separator: "\0").map { $0.trimmingCharacters(in: .newlines) }.filter { !$0.isEmpty }
    }

    private static func unique(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
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

    private static var gitEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        return env
    }

    private static func git(_ args: [String], in directory: URL) throws -> String {
        let result = try ProcessRunner.run(
            executable: URL(fileURLWithPath: WorktreeManager.gitPath), arguments: args, cwd: directory,
            environment: gitEnvironment
        )
        guard result.status == 0 else {
            throw AgentRuntimeError("git \(args.joined(separator: " ")) exited \(result.status): \(result.stderr)")
        }
        return result.stdout
    }
}
