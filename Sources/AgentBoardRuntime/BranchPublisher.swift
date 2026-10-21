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
    case privateTerm(term: String, site: PrivateTermSite)
    case privateTermCheckFailed(detail: String)

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
        case .privateTerm(let term, let site):
            return "Refused to publish: the private term \"\(term)\" appears in \(site). Nothing was pushed. "
                + "Remove it, or change the project's private terms in its PR Follow-Through settings."
        case .privateTermCheckFailed(let detail):
            return "Refused to publish: the private-term check could not read what would be sent, "
                + "so nothing was pushed: \(detail)"
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

    public static func refExists(_ ref: String) -> [String] {
        ["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"]
    }

    public static let emptyTree = ["hash-object", "-t", "tree", "/dev/null"]

    /// Every message on `branch` that `exclude` lacks; a nil `exclude` means the branch's whole history.
    public static func commitMessages(branch: String, exclude: String?) -> [String] {
        ["log", "-z", "--format=%B", exclude.map { "\($0)..refs/heads/\(branch)" } ?? "refs/heads/\(branch)"]
    }

    /// `since` is a ref (diffed from its merge base with the branch) or, with `fromTree`, a tree.
    public static func diff(branch: String, since: String, fromTree: Bool, nameOnly: Bool) -> [String] {
        let range = fromTree ? [since, "refs/heads/\(branch)"] : ["\(since)...refs/heads/\(branch)"]
        let shape = nameOnly
            ? ["--name-only", "-z", "--diff-filter=d"]
            : ["--src-prefix=a/", "--dst-prefix=b/"]
        return ["-c", "core.quotepath=false", "diff", "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames"]
            + shape + range + ["--"]
    }

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
    /// The project's `prFollowThrough.privateTerms` (SPEC §13.5).
    public var privateTerms: [String]

    public init(repoPath: URL, privateTerms: [String] = []) {
        self.repoPath = repoPath
        self.privateTerms = privateTerms
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

    /// SPEC §13.5: throws `privateTerm` when anything this publish would send names one of
    /// `privateTerms`. What is sent is measured from `<remote>/<base>`; with no such ref, from the
    /// branch's whole history.
    public func refusePrivateTerms(
        branch: String, publishedAs: String? = nil, base: String?, remote: String = "origin",
        title: String? = nil, body: String? = nil
    ) throws {
        guard privateTerms.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return
        }
        let remoteBase = base.map { "refs/remotes/\(remote)/\($0)" }
        let exclude = try remoteBase.flatMap { try git(PublishCommand.refExists($0)).status == 0 ? $0 : nil }
        let since = try exclude ?? checked(PublishCommand.emptyTree).trimmingCharacters(in: .whitespacesAndNewlines)
        let fromTree = exclude == nil
        let outgoing = OutgoingPublish(
            publishedBranch: publishedAs ?? branch,
            title: title,
            body: body,
            commitMessages: try checked(PublishCommand.commitMessages(branch: branch, exclude: exclude)),
            changedPaths: try checked(PublishCommand.diff(branch: branch, since: since, fromTree: fromTree, nameOnly: true))
                .split(separator: "\0").map(String.init),
            diff: try checked(PublishCommand.diff(branch: branch, since: since, fromTree: fromTree, nameOnly: false))
        )
        if let match = PrivateTermGuard.firstMatch(terms: privateTerms, in: outgoing) {
            throw PublishFailure.privateTerm(term: match.term, site: match.site)
        }
    }

    // MARK: Actions

    /// `publishedAs` is the name the branch takes on the remote; the local branch is never renamed.
    /// `base` bounds what the private-term guard reads.
    public func push(
        branch: String, publishedAs: String? = nil, base: String? = nil, remote: String = "origin"
    ) throws -> PushResult {
        try requireRemote(remote)
        try requireBranch(branch)
        try refusePrivateTerms(branch: branch, publishedAs: publishedAs, base: base, remote: remote)
        return try pushChecked(branch: branch, publishedAs: publishedAs, remote: remote)
    }

    private func pushChecked(branch: String, publishedAs: String?, remote: String) throws -> PushResult {
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
        try refusePrivateTerms(
            branch: branch, publishedAs: publishedAs, base: base, remote: remote, title: title, body: body
        )
        let gh = try requireGh()
        let pushed = try pushChecked(branch: branch, publishedAs: publishedAs, remote: remote)
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

    private func checked(_ arguments: [String]) throws -> String {
        let result = try git(arguments)
        guard result.status == 0 else { throw PublishFailure.privateTermCheckFailed(detail: Self.detail(result)) }
        return result.stdout
    }

    private static func detail(_ result: CommandResult) -> String {
        [result.stderr, result.stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "exit \(result.status)"
    }
}
