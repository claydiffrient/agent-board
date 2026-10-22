import AgentBoardCore
import Foundation

/// One row of `gh search prs`: an open pull request the user authored.
public struct AuthoredPullRequest: Sendable, Equatable, Hashable {
    /// `owner/name` exactly as GitHub spells it.
    public var repository: String
    public var number: Int
    public var url: String
    public var title: String
    public var isDraft: Bool

    public init(repository: String, number: Int, url: String, title: String, isDraft: Bool = false) {
        self.repository = repository
        self.number = number
        self.url = url
        self.title = title
        self.isDraft = isDraft
    }
}

public struct PullRequestWatchFailure: Error, CustomStringConvertible, Equatable, Sendable {
    public let description: String
    /// `gh` is missing or not logged in: no later poll can succeed until the human fixes it.
    public let ghUnavailable: Bool

    public init(_ description: String, ghUnavailable: Bool) {
        self.description = description
        self.ghUnavailable = ghUnavailable
    }
}

/// Reads the user's open pull requests and their review state for PR follow-through (SPEC §13.1).
/// Synchronous and blocking: call it off the main actor.
public struct PullRequestWatchReader: Sendable {
    public var gh: any GhRunning

    public init(gh: any GhRunning = SystemGh()) {
        self.gh = gh
    }

    public static let searchArguments = [
        "search", "prs", "--author=@me", "--state=open",
        "--json", "repository,number,url,title,isDraft", "--limit", "1000",
    ]

    /// `gh` exits 4 when it needs `gh auth login`.
    static let authRequiredStatus: Int32 = 4

    /// Every open pull request the user authored, drafts included; the caller decides what to skip.
    public func authored(cwd: URL) throws -> [AuthoredPullRequest] {
        let stdout = try run(Self.searchArguments, cwd: cwd, what: "gh search prs")
        guard let hits = Self.parseSearch(stdout) else {
            throw PullRequestWatchFailure("`gh search prs` printed no list: \(stdout)", ghUnavailable: false)
        }
        return hits
    }

    public static func graphQLArguments(owner: String, name: String, numbers: [Int]) -> [String] {
        ["api", "graphql", "-f", "query=\(query(numbers: numbers))", "-f", "owner=\(owner)", "-f", "name=\(name)"]
    }

    /// One query for every listed pull request in `owner/name`. Drafts and anything GitHub no longer
    /// returns are left out, feedback the viewer wrote never becomes an item, and the checks named in
    /// `ignoring` count toward neither the checks state nor the failed checks.
    public func snapshots(
        owner: String, name: String, numbers: [Int], ignoring: Set<String> = [], cwd: URL
    ) throws -> [PRSnapshot] {
        guard !numbers.isEmpty else { return [] }
        let arguments = Self.graphQLArguments(owner: owner, name: name, numbers: numbers)
        let stdout = try run(arguments, cwd: cwd, what: "gh api graphql")
        guard let snapshots = Self.parseSnapshots(stdout, owner: owner, name: name, ignoring: ignoring) else {
            throw PullRequestWatchFailure("`gh api graphql` printed no repository: \(stdout)", ghUnavailable: false)
        }
        return snapshots
    }

    public static let logTailLines = 200

    public static func failedLogArguments(owner: String, name: String, jobId: Int64) -> [String] {
        ["run", "view", "--job", "\(jobId)", "--log-failed", "--repo", "\(owner)/\(name)"]
    }

    /// The last `logTailLines` lines of a GitHub Actions job's failed steps, or nil when `gh` cannot read them.
    public func failedLogTail(owner: String, name: String, jobId: Int64, cwd: URL) -> String? {
        let arguments = Self.failedLogArguments(owner: owner, name: name, jobId: jobId)
        guard let result = try? gh.run(arguments, cwd: cwd), result.status == 0 else { return nil }
        var lines = result.stdout.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        while lines.last?.allSatisfy(\.isWhitespace) == true { lines.removeLast() }
        return lines.isEmpty ? nil : lines.suffix(Self.logTailLines).joined(separator: "\n")
    }

    private func run(_ arguments: [String], cwd: URL, what: String) throws -> String {
        let result: CommandResult
        do {
            result = try gh.run(arguments, cwd: cwd)
        } catch {
            throw PullRequestWatchFailure("\(error)", ghUnavailable: true)
        }
        guard result.status == 0 else {
            let said = [result.stderr, result.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "exit \(result.status)"
            let unauthenticated = result.status == Self.authRequiredStatus || said.contains("gh auth login")
            if unauthenticated {
                throw PullRequestWatchFailure("`gh` is not logged in; run `gh auth login`.", ghUnavailable: true)
            }
            throw PullRequestWatchFailure("`\(what)` failed: \(said)", ghUnavailable: false)
        }
        return result.stdout
    }

    static func query(numbers: [Int]) -> String {
        let pullRequests = numbers.map { number in
            """
            pr\(number): pullRequest(number: \(number)) {
              number url title isDraft headRefName headRefOid baseRefName reviewDecision mergeable
              isCrossRepository headRepository { nameWithOwner }
              labels(first: 100) { nodes { name } }
              baseRef {
                refUpdateRule { requiredStatusCheckContexts }
                rules(first: 100) {
                  nodes { parameters { ... on RequiredStatusChecksParameters { requiredStatusChecks { context } } } }
                }
              }
              commits(last: 1) {
                nodes { commit { statusCheckRollup { state contexts(first: 100) { nodes {
                  ... on CheckRun {
                    id databaseId name status conclusion startedAt completedAt detailsUrl summary
                    checkSuite { app { slug } } isRequired(pullRequestNumber: \(number))
                  }
                  ... on StatusContext {
                    id context state targetUrl description isRequired(pullRequestNumber: \(number))
                  }
                } } } } }
              }
              reviewThreads(first: 100) {
                nodes { id isResolved isOutdated comments(last: 1) { nodes { author { login } body url path line } } }
              }
              reviews(last: 50) { nodes { id state body url submittedAt author { login } } }
              timelineItems(last: 100, itemTypes: [REVIEW_REQUESTED_EVENT, REVIEW_REQUEST_REMOVED_EVENT]) {
                nodes {
                  __typename
                  ... on ReviewRequestedEvent { createdAt requestedReviewer { ... on User { login } ... on Bot { login } } }
                  ... on ReviewRequestRemovedEvent { createdAt requestedReviewer { ... on User { login } ... on Bot { login } } }
                }
              }
            }
            """
        }
        return """
        query($owner: String!, $name: String!) {
          viewer { login }
          repository(owner: $owner, name: $name) {
        \(pullRequests.joined(separator: "\n"))
          }
        }
        """
    }

    public static func parseSearch(_ json: String) -> [AuthoredPullRequest]? {
        struct Row: Decodable {
            struct Repository: Decodable { let nameWithOwner: String }
            let repository: Repository
            let number: Int
            let url: String
            let title: String
            let isDraft: Bool?
        }
        guard let rows = try? JSONDecoder().decode([Row].self, from: Data(json.utf8)) else { return nil }
        return rows.map {
            AuthoredPullRequest(
                repository: $0.repository.nameWithOwner, number: $0.number, url: $0.url, title: $0.title,
                isDraft: $0.isDraft ?? false
            )
        }
    }

    public static func parseSnapshots(
        _ json: String, owner: String, name: String, ignoring: Set<String> = []
    ) -> [PRSnapshot]? {
        guard let response = try? JSONDecoder().decode(GraphQLResponse.self, from: Data(json.utf8)),
              let repository = response.data?.repository
        else { return nil }
        let viewer = response.data?.viewer?.login
        return repository.values.compactMap { $0 }
            .filter { !$0.isDraft }
            .sorted { $0.number < $1.number }
            .map { snapshot(of: $0, owner: owner, name: name, viewer: viewer, ignoring: ignoring) }
    }

    private static func snapshot(
        of pr: GraphQLResponse.PullRequest, owner: String, name: String, viewer: String?, ignoring: Set<String>
    ) -> PRSnapshot {
        func byViewer(_ author: GraphQLResponse.Author?) -> Bool {
            guard let viewer, let login = author?.login else { return false }
            return login.caseInsensitiveCompare(viewer) == .orderedSame
        }
        var items: [PRSnapshotItem] = []
        for thread in pr.reviewThreads?.nodes ?? [] where !thread.isResolved && !thread.isOutdated {
            guard let latest = thread.comments?.nodes.last, !byViewer(latest.author) else { continue }
            items.append(PRSnapshotItem(
                githubNodeId: thread.id, kind: .thread, author: latest.author?.login, body: latest.body,
                path: latest.path, line: latest.line, url: latest.url
            ))
        }
        // A review body stands until its author reviews again; an approval's body is not feedback.
        var latestByAuthor: [String: GraphQLResponse.Review] = [:]
        for review in pr.reviews?.nodes ?? [] where review.state != "PENDING" && review.state != "DISMISSED" {
            guard let login = review.author?.login, !byViewer(review.author) else { continue }
            latestByAuthor[login.lowercased()] = review
        }
        for review in latestByAuthor.values.sorted(by: { $0.id < $1.id })
        where review.state != "APPROVED" && !review.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(PRSnapshotItem(
                githubNodeId: review.id, kind: .review, author: review.author?.login, body: review.body, url: review.url
            ))
        }
        let standing = standings(of: pr, byViewer: byViewer)
        if pr.mergeable == "CONFLICTING" {
            items.append(PRSnapshotItem(
                githubNodeId: PRItem.conflictNodeId(head: pr.headRefOid), kind: .conflict,
                body: "`\(pr.headRefName)` conflicts with `\(pr.baseRefName)`, so GitHub cannot merge it.", url: pr.url
            ))
        }
        return PRSnapshot(
            repoOwner: owner, repoName: name, number: pr.number, url: pr.url, title: pr.title, isDraft: pr.isDraft,
            headRef: pr.headRefName, headOid: pr.headRefOid, baseRef: pr.baseRefName,
            reviewDecision: pr.reviewDecision,
            approvedBy: standing.approvedBy, changesRequestedBy: standing.changesRequestedBy,
            checksState: checksState(of: pr, ignoring: ignoring),
            mergeable: pr.mergeable,
            labels: pr.labels?.nodes.map(\.name) ?? [],
            items: items,
            isCrossRepository: pr.isCrossRepository ?? false,
            headRepository: pr.headRepository?.nameWithOwner,
            failedChecks: failedChecks(of: pr, ignoring: ignoring)
        )
    }

    /// SPEC §13.1: when the PR requires checks only those count, and one that has not
    /// reported is pending; otherwise every reported check and the rollup count. Only each check's
    /// latest run counts. Failure, NEUTRAL included, outweighs pending. Nil means nothing is
    /// required and nothing counted has reported. Ignored checks leave both sets, and the rollup too
    /// once one of them has reported, since its state includes theirs.
    private static func checksState(of pr: GraphQLResponse.PullRequest, ignoring: Set<String>) -> String? {
        let rollup = pr.commits?.nodes.last?.commit.statusCheckRollup
        let all = latestRuns(of: pr)
        let reported = all.filter { !ignoring.contains($0.key) }
        let required = requiredChecks(of: pr).subtracting(ignoring)
        let outcomes: [CheckOutcome]
        if required.isEmpty {
            guard let rollup else { return nil }
            let rollupCounts = reported.count == all.count
            outcomes = reported.values.map(\.outcome) + (rollupCounts ? [CheckOutcome(state: rollup.state)] : [])
            guard !outcomes.isEmpty else { return nil }
        } else {
            outcomes = required.map { reported[$0]?.outcome ?? .pending }
        }
        return (outcomes.max() ?? .success).rawValue
    }

    /// The counted checks, by the same rule as `checksState`, whose latest run failed, in name order.
    private static func failedChecks(of pr: GraphQLResponse.PullRequest, ignoring: Set<String>) -> [PRFailedCheck] {
        let reported = latestRuns(of: pr).filter { !ignoring.contains($0.key) }
        let required = requiredChecks(of: pr).subtracting(ignoring)
        let counted = required.isEmpty ? Array(reported.values) : required.compactMap { reported[$0] }
        return counted.filter { $0.outcome == .failure }.sorted { $0.name < $1.name }.compactMap(\.failed)
    }

    /// The contexts' own `isRequired` flags, plus what protection and rulesets name: those reads may
    /// come back empty, but they alone cover a required check that has not reported yet (SPEC §13.1).
    private static func requiredChecks(of pr: GraphQLResponse.PullRequest) -> Set<String> {
        let flagged = contexts(of: pr).filter(\.isRequired).map(\.name)
        return Set(
            flagged
                + (pr.baseRef?.refUpdateRule?.requiredStatusCheckContexts ?? [])
                + (pr.baseRef?.rules?.nodes ?? []).flatMap { $0.parameters?.requiredStatusChecks ?? [] }.map(\.context)
        )
    }

    private static func contexts(of pr: GraphQLResponse.PullRequest) -> [GraphQLResponse.Check] {
        pr.commits?.nodes.last?.commit.statusCheckRollup?.contexts?.nodes.compactMap(\.check) ?? []
    }

    /// Ordered by start time, then completion time, then list order, so a rerun replaces the run it reran.
    private static func latestRuns(of pr: GraphQLResponse.PullRequest) -> [String: GraphQLResponse.Check] {
        var latest: [String: GraphQLResponse.Check] = [:]
        for check in contexts(of: pr) {
            if let held = latest[check.name]?.ranAt, let ranAt = check.ranAt, ranAt < held { continue }
            latest[check.name] = check
        }
        return latest
    }
}

private enum CheckOutcome: String, Comparable {
    case success = "SUCCESS"
    case pending = "PENDING"
    case failure = "FAILURE"

    private var rank: Int {
        switch self {
        case .success: 0
        case .pending: 1
        case .failure: 2
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }

    /// A commit status or rollup state.
    init(state: String) {
        switch state {
        case "SUCCESS": self = .success
        case "PENDING", "EXPECTED": self = .pending
        default: self = .failure
        }
    }

    init(status: String?, conclusion: String?) {
        guard status == "COMPLETED", let conclusion else {
            self = .pending
            return
        }
        self = conclusion == "SUCCESS" || conclusion == "SKIPPED" ? .success : .failure
    }
}

extension PullRequestWatchReader {
    /// Each reviewer stands by their latest approving or change-requesting review; a review request
    /// made after a CHANGES_REQUESTED leaves that reviewer pending until a later removal of the
    /// request. Readiness reads this only when `reviewDecision` is null (SPEC §13.1).
    fileprivate static func standings(
        of pr: GraphQLResponse.PullRequest, byViewer: (GraphQLResponse.Author?) -> Bool
    ) -> (approvedBy: [String], changesRequestedBy: [String]) {
        let iso = ISO8601DateFormatter()
        var latest: [String: (login: String, review: GraphQLResponse.Review)] = [:]
        for review in pr.reviews?.nodes ?? [] {
            guard let login = review.author?.login, !byViewer(review.author) else { continue }
            switch review.state {
            case "APPROVED", "CHANGES_REQUESTED": latest[login.lowercased()] = (login, review)
            case "DISMISSED": latest[login.lowercased()] = nil
            default: continue
            }
        }
        var requestedAt: [String: Date] = [:]
        var removedAt: [String: Date] = [:]
        for event in pr.timelineItems?.nodes ?? [] {
            guard let login = event.requestedReviewer?.login?.lowercased(),
                  let at = event.createdAt.flatMap({ iso.date(from: $0) })
            else { continue }
            switch event.__typename {
            case "ReviewRequestedEvent": requestedAt[login] = max(at, requestedAt[login] ?? at)
            case "ReviewRequestRemovedEvent": removedAt[login] = max(at, removedAt[login] ?? at)
            default: continue
            }
        }
        var approvedBy: [String] = []
        var changesRequestedBy: [String] = []
        for (key, entry) in latest.sorted(by: { $0.key < $1.key }) {
            if entry.review.state == "APPROVED" {
                approvedBy.append(entry.login)
                continue
            }
            let submitted = entry.review.submittedAt.flatMap { iso.date(from: $0) }
            if let submitted, let requested = requestedAt[key], requested > submitted,
               removedAt[key].map({ $0 < requested }) ?? true { continue }
            changesRequestedBy.append(entry.login)
        }
        return (approvedBy, changesRequestedBy)
    }
}

private struct GraphQLResponse: Decodable {
    struct Payload: Decodable {
        let viewer: Author?
        let repository: [String: PullRequest?]?
    }

    struct Author: Decodable { let login: String }
    struct Nodes<T: Decodable>: Decodable { let nodes: [T] }
    struct Label: Decodable { let name: String }
    struct Repository: Decodable { let nameWithOwner: String }
    struct Rollup: Decodable {
        let state: String
        let contexts: Nodes<CheckContext>?
    }

    struct Check {
        let name: String
        let outcome: CheckOutcome
        /// GitHub's ISO 8601 timestamps all end in `Z`, so they order correctly as strings.
        let ranAt: String?
        /// Nil when GitHub gave the run no node id.
        let failed: PRFailedCheck?
        let isRequired: Bool
    }

    struct App: Decodable { let slug: String? }
    struct CheckSuite: Decodable { let app: App? }

    /// A CheckRun carries name, status, conclusion and its run times; a StatusContext carries context and state.
    struct CheckContext: Decodable {
        let id: String?
        let databaseId: Int64?
        let name: String?
        let status: String?
        let conclusion: String?
        let startedAt: String?
        let completedAt: String?
        let detailsUrl: String?
        let summary: String?
        let checkSuite: CheckSuite?
        let context: String?
        let state: String?
        let targetUrl: String?
        let description: String?
        let isRequired: Bool?

        var check: Check? {
            if let name {
                let outcome = CheckOutcome(status: status, conclusion: conclusion)
                let failed = id.map { id in
                    PRFailedCheck(
                        githubNodeId: id, name: name, url: detailsUrl,
                        summary: Self.text(summary) ?? "It concluded \(conclusion ?? status ?? "without a result").",
                        jobId: checkSuite?.app?.slug == "github-actions" ? databaseId : nil
                    )
                }
                return Check(
                    name: name, outcome: outcome, ranAt: startedAt ?? completedAt, failed: failed,
                    isRequired: isRequired ?? false
                )
            }
            if let context, let state {
                let failed = id.map { id in
                    PRFailedCheck(
                        githubNodeId: id, name: context, url: targetUrl,
                        summary: Self.text(description) ?? "Its status is \(state)."
                    )
                }
                return Check(
                    name: context, outcome: CheckOutcome(state: state), ranAt: nil, failed: failed,
                    isRequired: isRequired ?? false
                )
            }
            return nil
        }

        private static func text(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
            return trimmed
        }
    }

    struct RefUpdateRule: Decodable { let requiredStatusCheckContexts: [String]? }
    struct RequiredCheck: Decodable { let context: String }
    struct RuleParameters: Decodable { let requiredStatusChecks: [RequiredCheck]? }
    struct Rule: Decodable { let parameters: RuleParameters? }

    struct BaseRef: Decodable {
        let refUpdateRule: RefUpdateRule?
        let rules: Nodes<Rule>?
    }

    struct Commit: Decodable { let statusCheckRollup: Rollup? }
    struct CommitNode: Decodable { let commit: Commit }

    struct Comment: Decodable {
        let author: Author?
        let body: String
        let url: String?
        let path: String?
        let line: Int?
    }

    struct Thread: Decodable {
        let id: String
        let isResolved: Bool
        let isOutdated: Bool
        let comments: Nodes<Comment>?
    }

    struct Review: Decodable {
        let id: String
        let state: String
        let body: String
        let url: String?
        let submittedAt: String?
        let author: Author?
    }

    /// A review request or its removal. A team request has no login and never matches a reviewer.
    struct ReviewRequest: Decodable {
        struct Reviewer: Decodable { let login: String? }
        let __typename: String?
        let createdAt: String?
        let requestedReviewer: Reviewer?
    }

    struct PullRequest: Decodable {
        let number: Int
        let url: String
        let title: String
        let isDraft: Bool
        let headRefName: String
        let headRefOid: String
        let baseRefName: String
        let baseRef: BaseRef?
        let reviewDecision: String?
        let mergeable: String?
        let isCrossRepository: Bool?
        let headRepository: Repository?
        let labels: Nodes<Label>?
        let commits: Nodes<CommitNode>?
        let reviewThreads: Nodes<Thread>?
        let reviews: Nodes<Review>?
        let timelineItems: Nodes<ReviewRequest>?
    }

    let data: Payload?
}
