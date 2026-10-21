import Foundation

/// Posts publishing's factual replies (SPEC §13.2): a reply on a review thread, or a comment on the
/// pull request for a review body, which has no thread. It never resolves anything. Synchronous and
/// blocking: call it off the main actor.
public struct PullRequestReplier: Sendable {
    public var gh: any GhRunning

    public init(gh: any GhRunning = SystemGh()) {
        self.gh = gh
    }

    static let threadReplyMutation = """
    mutation($thread: ID!, $body: String!) {
      addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $thread, body: $body}) { comment { url } }
    }
    """

    /// `-f` sends each value as a raw string, so a body is never read as a file or a typed value.
    public static func threadReplyArguments(threadId: String, body: String) -> [String] {
        ["api", "graphql", "-f", "query=\(threadReplyMutation)", "-f", "thread=\(threadId)", "-f", "body=\(body)"]
    }

    public static func commentArguments(owner: String, name: String, number: Int, body: String) -> [String] {
        ["api", "repos/\(owner)/\(name)/issues/\(number)/comments", "-f", "body=\(body)"]
    }

    /// The reply's URL.
    public func replyToThread(threadId: String, body: String, cwd: URL) throws -> String {
        let stdout = try run(Self.threadReplyArguments(threadId: threadId, body: body), cwd: cwd)
        struct Response: Decodable {
            struct Payload: Decodable {
                struct Reply: Decodable {
                    struct Comment: Decodable { let url: String }
                    let comment: Comment
                }
                let addPullRequestReviewThreadReply: Reply?
            }
            let data: Payload?
        }
        guard let url = (try? JSONDecoder().decode(Response.self, from: Data(stdout.utf8)))?
            .data?.addPullRequestReviewThreadReply?.comment.url
        else { throw PullRequestCheckFailure("`gh api graphql` printed no reply: \(stdout)") }
        return url
    }

    /// The comment's URL.
    public func comment(owner: String, name: String, number: Int, body: String, cwd: URL) throws -> String {
        let stdout = try run(Self.commentArguments(owner: owner, name: name, number: number, body: body), cwd: cwd)
        struct Response: Decodable {
            let htmlURL: String
            enum CodingKeys: String, CodingKey { case htmlURL = "html_url" }
        }
        guard let url = (try? JSONDecoder().decode(Response.self, from: Data(stdout.utf8)))?.htmlURL else {
            throw PullRequestCheckFailure("`gh api` printed no comment: \(stdout)")
        }
        return url
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
}
