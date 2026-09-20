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

    /// Whether the board should call the human's attention to this task after it reached `done`.
    public var needsAttention: Bool {
        switch self {
        case .pending, .unlanded: return true
        case .noBranch, .landed: return false
        }
    }

    public var label: String {
        switch self {
        case .pending: return "landing unknown"
        case .noBranch: return "nothing to land"
        case .landed: return "landed"
        case .unlanded: return "not landed"
        }
    }
}
