import AgentBoardCore
import Foundation

/// Looks up the pull request an epic is asked to build on and refuses one it cannot (SPEC §6.1
/// `create_epic`). Synchronous and blocking: call it off the main actor.
public struct EpicUpstreamReader: Sendable {
    public var gh: any GhRunning

    public init(gh: any GhRunning = SystemGh()) {
        self.gh = gh
    }

    public static func arguments(number: Int, repository: String) -> [String] {
        ["pr", "view", String(number), "--repo", repository, "--json", "number,url,state,headRefName,isCrossRepository"]
    }

    /// The pull request `number` in the GitHub repository behind `repoPath`'s `origin`, as an upstream.
    public func upstream(pullRequest number: Int, repoPath: URL) throws -> EpicUpstream {
        let remote = try BranchPublisher(repoPath: repoPath).requireRemote()
        guard let repository = PullRequestLaunch.githubSlug(remoteURL: remote) else {
            throw PullRequestCheckFailure(
                "This project's `origin` (\(remote)) is not a GitHub repository, so it has no pull request #\(number)."
            )
        }
        let result = try gh.run(Self.arguments(number: number, repository: repository), cwd: repoPath)
        guard result.status == 0 else {
            let said = [result.stderr, result.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "exit \(result.status)"
            throw PullRequestCheckFailure("Could not read pull request #\(number) in \(repository): \(said)")
        }
        return try Self.upstream(from: result.stdout, number: number)
    }

    public static func upstream(from json: String, number: Int) throws -> EpicUpstream {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = object["state"] as? String,
              let url = object["url"] as? String,
              let headRef = object["headRefName"] as? String
        else {
            throw PullRequestCheckFailure("`gh pr view` printed no pull request for #\(number): \(json)")
        }
        guard state.uppercased() == "OPEN" else {
            throw PullRequestCheckFailure(
                "Pull request #\(number) is \(state.lowercased()), not open; an epic can only build on an open pull request."
            )
        }
        if object["isCrossRepository"] as? Bool ?? false {
            throw PullRequestCheckFailure(
                "Pull request #\(number) comes from a fork; an epic can only build on a pull request whose head "
                    + "branch is in this repository."
            )
        }
        return EpicUpstream(
            headRef: headRef,
            pullRequest: PullRequestReference(url: url, number: object["number"] as? Int ?? number)
        )
    }
}
