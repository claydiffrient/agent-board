import Foundation

/// What the app did about a PR. It never creates one: `--web` opens a prefilled compare page,
/// and the fallback hands the same page to the browser directly (SPEC §5.2 step 4, D8).
public enum PullRequestOutcome: Sendable, Equatable {
    /// `gh` opened the browser itself.
    case openedByGh
    /// `gh` was missing or failed; this URL is for the caller to open.
    case openInBrowser(URL, reason: String)
}

public enum PullRequestLaunch {
    public static func ghArguments(baseBranch: String, headBranch: String) -> [String] {
        ["pr", "create", "--web", "--base", baseBranch, "--head", headBranch]
    }

    /// `owner/repo` from a GitHub remote in scp-like, https, or ssh:// form. Nil for non-GitHub hosts.
    public static func githubSlug(remoteURL: String) -> String? {
        let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var host: String
        var path: String
        if let range = trimmed.range(of: "://") {
            let rest = String(trimmed[range.upperBound...])
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            host = String(rest[..<slash])
            path = String(rest[rest.index(after: slash)...])
        } else if let colon = trimmed.firstIndex(of: ":") {
            host = String(trimmed[..<colon])
            path = String(trimmed[trimmed.index(after: colon)...])
        } else {
            return nil
        }

        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        if let portColon = host.firstIndex(of: ":") { host = String(host[..<portColon]) }
        guard host.lowercased() == "github.com" else { return nil }

        if path.hasSuffix(".git") { path = String(path.dropLast(4)) }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = path.split(separator: "/")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return "\(parts[0])/\(parts[1])"
    }

    /// The same page `gh` would open with `--web`, built by hand.
    public static func compareURL(remoteURL: String, baseBranch: String, headBranch: String) -> URL? {
        guard let slug = githubSlug(remoteURL: remoteURL) else { return nil }
        let allowed = CharacterSet.urlPathAllowed
        guard let base = baseBranch.addingPercentEncoding(withAllowedCharacters: allowed),
              let head = headBranch.addingPercentEncoding(withAllowedCharacters: allowed)
        else { return nil }
        return URL(string: "https://github.com/\(slug)/compare/\(base)...\(head)?expand=1")
    }
}

/// Runs `gh` in `--web` mode in the project repo, falling back to the compare URL.
public struct PullRequestOpener: Sendable {
    public static let searchPaths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]

    public var repoPath: URL

    public init(repoPath: URL) {
        self.repoPath = repoPath
    }

    public static func ghExecutable() -> URL? {
        searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    public func open(baseBranch: String, headBranch: String) throws -> PullRequestOutcome {
        guard let gh = Self.ghExecutable() else {
            return try fallback(baseBranch: baseBranch, headBranch: headBranch, reason: "gh is not installed")
        }
        let result = try ProcessRunner.run(
            executable: gh,
            arguments: PullRequestLaunch.ghArguments(baseBranch: baseBranch, headBranch: headBranch),
            cwd: repoPath,
            environment: ChildEnvironment.sanitized().merging(["GH_PROMPT_DISABLED": "1"]) { _, new in new }
        )
        guard result.status == 0 else {
            let detail = [result.stderr, result.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "exit \(result.status)"
            return try fallback(baseBranch: baseBranch, headBranch: headBranch, reason: "gh failed: \(detail)")
        }
        return .openedByGh
    }

    public func remoteURL(_ name: String = "origin") throws -> String {
        let result = try ProcessRunner.run(
            executable: URL(fileURLWithPath: WorktreeManager.gitPath),
            arguments: ["remote", "get-url", name],
            cwd: repoPath
        )
        guard result.status == 0 else {
            throw AgentRuntimeError("no git remote named \(name) in \(repoPath.path)")
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fallback(baseBranch: String, headBranch: String, reason: String) throws -> PullRequestOutcome {
        let remote = try remoteURL()
        guard let url = PullRequestLaunch.compareURL(remoteURL: remote, baseBranch: baseBranch, headBranch: headBranch) else {
            throw AgentRuntimeError("\(reason), and \(remote) is not a GitHub remote to build a compare URL from")
        }
        return .openInBrowser(url, reason: reason)
    }
}
