import AgentBoardCore
import Foundation

/// Reads a taken-over issue's text, comments and linked pull requests for its task (SPEC §13.8).
/// Synchronous and blocking: call it off the main actor.
public struct TakeoverIssueReader: Sendable {
    public var gh: any GhRunning

    public init(gh: any GhRunning = SystemGh()) {
        self.gh = gh
    }

    public static func arguments(url: String) -> [String] {
        ["issue", "view", url, "--json", "number,title,url,author,body,comments,closedByPullRequestsReferences"]
    }

    public func read(url: String, cwd: URL) throws -> TakeoverIssue {
        let stdout = try PullRequestWatchReader(gh: gh).run(Self.arguments(url: url), cwd: cwd, what: "gh issue view")
        guard let issue = Self.parse(stdout) else {
            throw PullRequestWatchFailure("`gh issue view` printed no issue: \(stdout)", ghUnavailable: false)
        }
        return issue
    }

    public static func parse(_ json: String) -> TakeoverIssue? {
        struct Author: Decodable { let login: String? }
        struct Comment: Decodable {
            let author: Author?
            let body: String?
            let url: String?
        }
        struct Linked: Decodable {
            let number: Int
            let url: String
        }
        struct Row: Decodable {
            let number: Int
            let title: String
            let url: String
            let author: Author?
            let body: String?
            let comments: [Comment]?
            let closedByPullRequestsReferences: [Linked]?
        }
        guard let row = try? JSONDecoder().decode(Row.self, from: Data(json.utf8)) else { return nil }
        return TakeoverIssue(
            number: row.number, title: row.title, url: row.url, author: row.author?.login, body: row.body ?? "",
            comments: (row.comments ?? []).map {
                TakeoverIssue.Comment(author: $0.author?.login, body: $0.body ?? "", url: $0.url)
            },
            linkedPullRequests: (row.closedByPullRequestsReferences ?? []).map {
                TakeoverIssue.LinkedPullRequest(number: $0.number, url: $0.url)
            }
        )
    }
}
