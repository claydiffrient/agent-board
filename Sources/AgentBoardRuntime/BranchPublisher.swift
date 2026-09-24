import AgentBoardCore
import Foundation

/// Why publishing stopped. Each case names one cause, so "you are not logged in to gh" never
/// reaches the orchestrator as a generic failure it has to spend a round trip diagnosing.
public enum PublishFailure: Error, CustomStringConvertible, Equatable, Sendable {
    case noRemote(name: String, repoPath: String)
    case ghMissing
    case ghNotAuthenticated(detail: String)
    case noSuchBranch(String)
    case pushFailed(branch: String, detail: String)
    case pullRequestFailed(detail: String)
    case noPullRequestURL(output: String)

    public var description: String {
        switch self {
        case .noRemote(let name, let repoPath):
            return "This project has no git remote named \"\(name)\". \(repoPath) is local-only, "
                + "so there is nowhere to push. Add a remote and try again."
        case .ghMissing:
            return "The GitHub CLI (`gh`) is not installed, so Agent Board cannot open a pull request. "
                + "Install it with `brew install gh`."
        case .ghNotAuthenticated(let detail):
            return "The GitHub CLI (`gh`) is installed but not authenticated. Run `gh auth login`.\n\(detail)"
        case .noSuchBranch(let branch):
            return "No branch named \"\(branch)\" exists in this repository, so there is nothing to push."
        case .pushFailed(let branch, let detail):
            return "Pushing \(branch) failed: \(detail)"
        case .pullRequestFailed(let detail):
            return "Opening the pull request failed: \(detail)"
        case .noPullRequestURL(let output):
            return "The pull request command succeeded but printed no URL:\n\(output)"
        }
    }
}

/// What publishing did. `alreadyUpToDate` and `alreadyOpen` are successes: the caller asked for a
/// state, and the state already holds.
public enum PushResult: Sendable, Equatable {
    case pushed(branch: String, remote: String, published: String? = nil)
    case alreadyUpToDate(branch: String, remote: String, published: String? = nil)

    public var summary: String {
        switch self {
        case .pushed(let branch, let remote, let published):
            return "pushed \(branch) to \(remote)\(Self.suffix(branch: branch, published: published))"
        case .alreadyUpToDate(let branch, let remote, let published):
            return "\(branch) was already up to date on \(remote)\(Self.suffix(branch: branch, published: published))"
        }
    }

    /// The published name is named only when it differs, so the untemplated case reads as it always did.
    private static func suffix(branch: String, published: String?) -> String {
        guard let published, published != branch else { return "" }
        return " as \(published)"
    }
}

public struct PullRequestResult: Sendable, Equatable {
    public var url: String
    public var push: PushResult
    /// True when a pull request for this branch was already open and its URL is being returned.
    public var alreadyOpen: Bool

    public init(url: String, push: PushResult, alreadyOpen: Bool) {
        self.url = url
        self.push = push
        self.alreadyOpen = alreadyOpen
    }
}

/// The argument lists, separated from running anything, so the shape of every command Agent Board
/// aims at a remote is asserted in tests without a repository or a network.
public enum PublishCommand {
    /// A fully-qualified refspec on both sides: an argument that reads as a branch name and cannot
    /// be mistaken for a remote, a tag, or — with an empty source — a delete.
    /// `published` renames the ref on the remote without touching the local branch: git writes the
    /// source ref to a differently named destination natively. Nil publishes the local name.
    public static func push(remote: String, branch: String, published: String? = nil) -> [String] {
        ["push", "--set-upstream", remote, "refs/heads/\(branch):refs/heads/\(published ?? branch)"]
    }

    public static func branchExists(_ branch: String) -> [String] {
        ["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"]
    }

    public static func remoteURL(_ remote: String) -> [String] {
        ["remote", "get-url", remote]
    }

    public static let ghAuthStatus = ["auth", "status"]

    public static func pullRequestCreate(base: String, head: String, title: String, body: String) -> [String] {
        ["pr", "create", "--base", base, "--head", head, "--title", title, "--body", body]
    }

    public static func openPullRequests(head: String) -> [String] {
        ["pr", "list", "--head", head, "--state", "open", "--json", "url", "--limit", "1"]
    }

    /// The first `https://…` line `gh pr create` printed. It writes the URL on stdout, but version
    /// and update notices share the stream.
    public static func pullRequestURL(in output: String) -> String? {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("https://") }
    }

    public static func firstURL(inListJSON json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        return rows.compactMap { $0["url"] as? String }.first
    }
}

/// Pushes a branch and opens its pull request from the project repository. Every precondition is
/// checked before anything leaves the machine, so a refusal names the cause rather than the symptom.
public struct BranchPublisher: Sendable {
    public var repoPath: URL

    public init(repoPath: URL) {
        self.repoPath = repoPath
    }

    private var gitURL: URL { URL(fileURLWithPath: WorktreeManager.gitPath) }

    private var ghEnvironment: [String: String] {
        ChildEnvironment.sanitized().merging(["GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1"]) { _, new in new }
    }

    // MARK: Preconditions

    @discardableResult
    public func requireRemote(_ remote: String = "origin") throws -> String {
        let result = try git(PublishCommand.remoteURL(remote))
        let url = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, !url.isEmpty else {
            throw PublishFailure.noRemote(name: remote, repoPath: repoPath.path)
        }
        return url
    }

    /// SPEC §5: what a project with no stored choice integrates standalone tasks by. Anything that
    /// stops `origin` being read — no remote, no repository, no git — means local merge.
    public func defaultStandaloneIntegration() -> StandaloneIntegration {
        (try? requireRemote()) == nil ? .localMerge : .pullRequest
    }

    public func standaloneIntegration(_ settings: ProjectSettings) -> StandaloneIntegration {
        settings.standaloneIntegration ?? defaultStandaloneIntegration()
    }

    public func requireBranch(_ branch: String) throws {
        let result = try git(PublishCommand.branchExists(branch))
        guard result.status == 0 else { throw PublishFailure.noSuchBranch(branch) }
    }

    /// `gh` present on disk and logged in, as two separate answers.
    @discardableResult
    public func requireGh() throws -> URL {
        guard let gh = PullRequestOpener.ghExecutable() else { throw PublishFailure.ghMissing }
        let status = try ProcessRunner.run(
            executable: gh, arguments: PublishCommand.ghAuthStatus, cwd: repoPath, environment: ghEnvironment
        )
        guard status.status == 0 else {
            throw PublishFailure.ghNotAuthenticated(detail: Self.detail(status))
        }
        return gh
    }

    // MARK: Actions

    /// `publishedAs` is the name the branch takes on the remote; the local branch is never renamed.
    public func push(branch: String, publishedAs: String? = nil, remote: String = "origin") throws -> PushResult {
        try requireRemote(remote)
        try requireBranch(branch)
        let result = try git(PublishCommand.push(remote: remote, branch: branch, published: publishedAs))
        guard result.status == 0 else {
            throw PublishFailure.pushFailed(branch: branch, detail: Self.detail(result))
        }
        let said = result.stdout + result.stderr
        return said.contains("Everything up-to-date")
            ? .alreadyUpToDate(branch: branch, remote: remote, published: publishedAs)
            : .pushed(branch: branch, remote: remote, published: publishedAs)
    }

    /// The pull request's head is the published name, not the local one — `gh` is only ever handed a
    /// ref that exists on the remote.
    public func openPullRequest(
        branch: String, publishedAs: String? = nil, base: String, title: String, body: String,
        remote: String = "origin"
    ) throws -> PullRequestResult {
        try requireRemote(remote)
        try requireBranch(branch)
        let gh = try requireGh()
        let pushed = try push(branch: branch, publishedAs: publishedAs, remote: remote)
        let head = publishedAs ?? branch

        let created = try ProcessRunner.run(
            executable: gh,
            arguments: PublishCommand.pullRequestCreate(base: base, head: head, title: title, body: body),
            cwd: repoPath,
            environment: ghEnvironment
        )
        if created.status == 0 {
            guard let url = PublishCommand.pullRequestURL(in: created.stdout + "\n" + created.stderr) else {
                throw PublishFailure.noPullRequestURL(output: Self.detail(created))
            }
            return PullRequestResult(url: url, push: pushed, alreadyOpen: false)
        }
        if let existing = try openPullRequestURL(branch: head, gh: gh) {
            return PullRequestResult(url: existing, push: pushed, alreadyOpen: true)
        }
        throw PublishFailure.pullRequestFailed(detail: Self.detail(created))
    }

    private func openPullRequestURL(branch: String, gh: URL) throws -> String? {
        let listed = try ProcessRunner.run(
            executable: gh, arguments: PublishCommand.openPullRequests(head: branch),
            cwd: repoPath, environment: ghEnvironment
        )
        guard listed.status == 0 else { return nil }
        return PublishCommand.firstURL(inListJSON: listed.stdout)
    }

    private func git(_ arguments: [String]) throws -> CommandResult {
        try ProcessRunner.run(executable: gitURL, arguments: arguments, cwd: repoPath)
    }

    private static func detail(_ result: CommandResult) -> String {
        [result.stderr, result.stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "exit \(result.status)"
    }
}
