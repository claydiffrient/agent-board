import Foundation

/// The open, same-repository pull request an epic builds on: its branch is cut from `headRef` and
/// published back onto it, and the epic ships when that pull request merges (SPEC §4, §6.1).
public struct EpicUpstream: Sendable, Equatable {
    public var headRef: String
    public var pullRequest: PullRequestReference

    public init(headRef: String, pullRequest: PullRequestReference) {
        self.headRef = headRef
        self.pullRequest = pullRequest
    }
}

public enum EpicUpstreamError: Error, CustomStringConvertible, Equatable, Sendable {
    case malformedHeadRef(String)
    case headIsBaseBranch(String)
    /// Another epic in the project that is neither done nor abandoned already builds on this pull request.
    case alreadyAdopted(pullRequest: Int, epicId: String, title: String)

    public var description: String {
        switch self {
        case .malformedHeadRef(let ref):
            return "\"\(ref)\" is not a usable branch name, so no epic can build on it."
        case .headIsBaseBranch(let ref):
            return "Pull request head \"\(ref)\" is the project's base branch; an epic cannot publish onto it."
        case .alreadyAdopted(let number, let epicId, let title):
            return "Epic \(epicId) (\(title)) already builds on pull request #\(number). Add tasks to that epic, "
                + "or close or abandon it first."
        }
    }
}
