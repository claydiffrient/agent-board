import AgentBoardCore
import Foundation

/// SPEC §13.8 manual adoption: the Pull Requests page's Watch pull request and a granted `watch_pr` both end
/// here. Reads the pull request from the project's `origin` with `gh pr view` and adopts it only when it is
/// open and not from a fork, with follow-through on. Synchronous and blocking: call it off the main actor.
public struct PullRequestAdopter: Sendable {
    public var gh: any GhRunning

    public init(gh: any GhRunning = SystemGh()) {
        self.gh = gh
    }

    public static func arguments(number: Int, repository: String) -> [String] {
        ["pr", "view", String(number), "--repo", repository, "--json", "number,url,title,state,isCrossRepository"]
    }

    /// Refusals are `PRVerdictRejection`s worded for the human; a `gh` that cannot run throws its own failure.
    public func adopt(number: Int, project: Project, db: AppDatabase, now: Int64 = .nowMillis) throws -> PRWatch {
        guard number > 0 else { throw PRVerdictRejection("A pull request number is a positive integer.") }
        guard project.settings.prFollowThrough.enabled else {
            throw PRVerdictRejection(
                "Adopting a pull request needs PR follow-through. Turn it on in the project's PR Follow-Through settings."
            )
        }
        let remote: String
        do {
            remote = try BranchPublisher(repoPath: URL(fileURLWithPath: project.repoPath)).requireRemote()
        } catch PublishFailure.noRemote {
            throw PRVerdictRejection("\(project.name) has no `origin`, so there is no pull request #\(number) to watch.")
        }
        guard let repository = PullRequestLaunch.githubSlug(remoteURL: remote),
              let (owner, name) = Self.split(repository)
        else { throw PRVerdictRejection("\(project.name)'s `origin` is not on GitHub.") }

        let result = try gh.run(Self.arguments(number: number, repository: repository), cwd: URL(fileURLWithPath: project.repoPath))
        guard result.status == 0 else {
            let said = [result.stderr, result.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "exit \(result.status)"
            throw PullRequestCheckFailure("`gh pr view \(number)` failed: \(said)")
        }
        guard let pr = Self.parse(result.stdout) else {
            throw PullRequestCheckFailure("`gh pr view \(number)` printed no pull request: \(result.stdout)")
        }
        guard pr.state == "OPEN" else {
            throw PRVerdictRejection("#\(number) is \(pr.state.lowercased()), not open, so there is nothing to watch.")
        }
        guard !pr.isCrossRepository else {
            throw PRVerdictRejection(
                "#\(number) comes from a fork. Follow-through pushes only to `\(repository)`, so a fork's pull request "
                    + "cannot be adopted."
            )
        }
        return try PRWatchStore(db).adoptManually(
            projectId: project.id, owner: owner, name: name, number: number, url: pr.url, title: pr.title, now: now
        )
    }

    struct ViewedPullRequest: Equatable {
        var url: String
        var title: String
        var state: String
        var isCrossRepository: Bool
    }

    static func parse(_ json: String) -> ViewedPullRequest? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = object["url"] as? String, let state = object["state"] as? String
        else { return nil }
        return ViewedPullRequest(
            url: url, title: object["title"] as? String ?? "", state: state.uppercased(),
            isCrossRepository: object["isCrossRepository"] as? Bool ?? false
        )
    }

    private static func split(_ repository: String) -> (String, String)? {
        let parts = repository.split(separator: "/").map(String.init)
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }
}
