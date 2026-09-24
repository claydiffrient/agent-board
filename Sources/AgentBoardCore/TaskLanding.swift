import GRDB

/// Where an accepted task's work ended up (SPEC §5).
///
/// `done` on its own cannot distinguish "reviewed and landed" from "reviewed, and the commits are
/// reachable only from a branch nobody will look at again". Every accept writes one of these, so
/// the second case is a state the board can render rather than an absence it cannot.
public enum TaskLanding: String, Codable, Sendable, CaseIterable, Equatable, DatabaseValueConvertible {
    /// The accept ran but has not yet heard back from git. Written inside the acceptance
    /// transaction and overwritten moments later by the real outcome; it survives only when the
    /// app died in between, which is exactly when the board must not claim the work landed.
    case pending

    /// There was no branch to land — the task committed nothing. A non-code task finishes here and
    /// is not stranded, which is why this is its own case and not `unlanded`.
    case noBranch = "no_branch"

    /// The target branch contains the task's commits.
    case landed

    /// The task has commits and its target branch does not contain them. The work is reachable only
    /// from the task branch until a human lands it.
    case unlanded

    /// A task in no epic, in a project that integrates by pull request: the accept merged nothing
    /// and the kept task branch waits for a pull request to be opened.
    case awaitingPullRequest = "awaiting_pull_request"

    /// A pull request is recorded for the task's branch and has not merged. `landingDetail` carries
    /// its URL, which the pill's number and the merge check both read.
    case pullRequestOpen = "pull_request_open"

    /// Whether the board should call the human's attention to this task after it reached `done`.
    public var needsAttention: Bool {
        switch self {
        case .pending, .unlanded, .awaitingPullRequest, .pullRequestOpen: return true
        case .noBranch, .landed: return false
        }
    }

    public var label: String {
        switch self {
        case .pending: return "landing unknown"
        case .noBranch: return "nothing to land"
        case .landed: return "landed"
        case .unlanded: return "not landed"
        case .awaitingPullRequest: return "PR pending"
        case .pullRequestOpen: return "PR open"
        }
    }
}

/// The landing details a pull request produces. An open or merged detail leads with the URL, so
/// `PullRequestReference(in:)` reads it back for the pill and the next merge check.
public enum PullRequestLanding {
    public static func awaitingDetail(branch: String, base: String) -> String {
        "`\(branch)` awaits a pull request into `\(base)`: this project integrates standalone tasks by "
            + "pull request, so the accept merged nothing locally."
    }

    public static func awaitingAdvice(branch: String) -> String {
        "Open one with `open_pull_request(branch: \"\(branch)\")`; the task is marked landed once GitHub "
            + "reports it merged."
    }

    public static func openDetail(_ pr: PullRequestReference, uncheckedBecause reason: String? = nil) -> String {
        let open = "\(pr.url) — pull request #\(pr.number) is open."
        guard let reason else { return open }
        return open + "\nIts state could not be checked, so this may be stale: \(reason)"
    }

    public static func mergedDetail(_ pr: PullRequestReference, commit: String?) -> String {
        "\(pr.url) — pull request #\(pr.number) merged" + (commit.map { " as \($0)." } ?? ".")
    }

    public static func closedDetail(_ pr: PullRequestReference, branch: String) -> String {
        "`\(branch)` did not land: pull request #\(pr.number) was closed without merging (\(pr.url))."
    }

    public static func closedAdvice(branch: String) -> String {
        "Reopen it, or open a new pull request from `\(branch)`."
    }
}
