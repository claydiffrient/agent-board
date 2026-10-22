import Foundation

/// Re-requests review after a pushed round (SPEC §13.2). Synchronous and blocking: call it off the main actor.
public struct PullRequestReviewRequester: Sendable {
    public var gh: any GhRunning

    public init(gh: any GhRunning = SystemGh()) {
        self.gh = gh
    }

    static func standingQuery(number: Int) -> String {
        """
        query($owner: String!, $name: String!) {
          viewer { login }
          repository(owner: $owner, name: $name) {
            pr\(number): pullRequest(number: \(number)) {
              reviews(last: 100) { nodes { state author { __typename login } } }
              reviewRequests(first: 100) { nodes { requestedReviewer { ... on User { login } ... on Bot { login } } } }
            }
          }
        }
        """
    }

    public static func standingArguments(owner: String, name: String, number: Int) -> [String] {
        ["api", "graphql", "-f", "query=\(standingQuery(number: number))", "-f", "owner=\(owner)", "-f", "name=\(name)"]
    }

    public static func requestArguments(owner: String, name: String, number: Int, reviewers: [String]) -> [String] {
        ["api", "repos/\(owner)/\(name)/pulls/\(number)/requested_reviewers"] + reviewers.flatMap { ["-f", "reviewers[]=\($0)"] }
    }

    /// Those of `authors` whose latest review is `CHANGES_REQUESTED` or `COMMENTED`, leaving out the
    /// viewer, bots, which GitHub will not request, and anyone whose request is still pending.
    public func reviewersToRequest(owner: String, name: String, number: Int, authors: [String], cwd: URL) throws -> [String] {
        guard !authors.isEmpty else { return [] }
        let stdout = try run(Self.standingArguments(owner: owner, name: name, number: number), cwd: cwd)
        guard let response = try? JSONDecoder().decode(Response.self, from: Data(stdout.utf8)),
              let pr = response.data?.repository?["pr\(number)"] ?? nil
        else { throw PullRequestCheckFailure("`gh api graphql` printed no pull request: \(stdout)") }
        let viewer = response.data?.viewer?.login.lowercased()
        let pending = Set((pr.reviewRequests?.nodes ?? []).compactMap { $0.requestedReviewer?.login?.lowercased() })
        var latest: [String: String] = [:]
        var bots: Set<String> = []
        for review in pr.reviews?.nodes ?? [] where review.state != "PENDING" && review.state != "DISMISSED" {
            guard let login = review.author?.login.lowercased() else { continue }
            latest[login] = review.state
            if review.author?.__typename == "Bot" { bots.insert(login) }
        }
        return authors.filter { author in
            let login = author.lowercased()
            return !login.hasSuffix("[bot]") && !bots.contains(login) && login != viewer && !pending.contains(login)
                && ["CHANGES_REQUESTED", "COMMENTED"].contains(latest[login])
        }
    }

    public func request(owner: String, name: String, number: Int, reviewers: [String], cwd: URL) throws {
        _ = try run(Self.requestArguments(owner: owner, name: name, number: number, reviewers: reviewers), cwd: cwd)
    }

    private func run(_ arguments: [String], cwd: URL) throws -> String {
        let result = try gh.run(arguments, cwd: cwd)
        guard result.status == 0 else {
            let said = [result.stderr, result.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "exit \(result.status)"
            throw PullRequestCheckFailure("`gh api` failed: \(said)")
        }
        return result.stdout
    }

    private struct Response: Decodable {
        struct Login: Decodable { let login: String }
        struct Author: Decodable {
            let __typename: String?
            let login: String
        }
        struct Review: Decodable {
            let state: String
            let author: Author?
        }
        struct Request: Decodable {
            struct Reviewer: Decodable { let login: String? }
            let requestedReviewer: Reviewer?
        }
        struct Nodes<T: Decodable>: Decodable { let nodes: [T] }
        struct PullRequest: Decodable {
            let reviews: Nodes<Review>?
            let reviewRequests: Nodes<Request>?
        }
        struct Payload: Decodable {
            let viewer: Login?
            let repository: [String: PullRequest?]?
        }
        let data: Payload?
    }
}
