import Foundation
import GRDB

/// Where a watched pull request is in the follow-through state machine (SPEC §4). Phase 1 writes
/// only some of these; the rest exist so later phases need no migration of stored values.
public enum PRWatchState: String, Codable, Sendable, CaseIterable, Equatable, DatabaseValueConvertible {
    case watching
    case settling
    case triaging
    case fixing
    case checking
    case publishing
    case awaitingCI = "awaiting_ci"
    case readyToVerify = "ready_to_verify"
    case verified
    case stale
    case parked
    case merged
    case closed
    /// The human chose Stop watching: the poll records nothing more on it and the page lists it nowhere.
    case stopped

    public var isTerminal: Bool { self == .merged || self == .closed }
}

public enum PRItemKind: String, Codable, Sendable, CaseIterable, Equatable, DatabaseValueConvertible {
    case thread
    case review
    /// A pull request conversation comment (SPEC §13.1).
    case comment
    case check
    case conflict
    case verifyFailure = "verify_failure"
}

public enum PRItemState: String, Codable, Sendable, CaseIterable, Equatable, DatabaseValueConvertible {
    case open
    case handled
    case dismissed
}

public enum PRItemVerdict: String, Codable, Sendable, CaseIterable, Equatable, DatabaseValueConvertible {
    case fix
    case answer
    case alreadyDone = "already_done"
    case followUp = "follow_up"
    case decision
}

public enum PRFollowupGrade: String, Codable, Sendable, CaseIterable, Equatable, DatabaseValueConvertible {
    case fixed
    case partly
    case notFixed = "not_fixed"
    case moot
    /// Only the pull request's author can do it on GitHub, so the check hands it to them as a decision
    /// rather than failing the round (SPEC §13.1).
    case needsAuthor = "needs_author"
}

public enum PRRoundReview: String, Codable, Sendable, CaseIterable, Equatable, DatabaseValueConvertible {
    case accepted
    case reopened
}

public struct PRWatch: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
    public static let databaseTableName = "pr_watch"

    public var id: String
    public var projectId: String
    public var repoOwner: String
    public var repoName: String
    public var number: Int
    public var url: String
    public var title: String
    public var isDraft: Bool
    public var headRef: String
    public var headOid: String
    /// When a poll first saw `headOid`; nil for a head that was already there when watching began.
    public var headChangedAt: Int64? = nil
    public var baseRef: String
    public var state: PRWatchState
    public var round: Int
    public var reviewDecision: String?
    public var checksState: String?
    public var mergeable: String?
    public var labelsJSON: String
    public var paused: Bool
    public var lastPolledAt: Int64?
    public var lastFeedbackAt: Int64?
    public var verifiedAt: Int64?
    public var estCostUSD: Double
    /// The head whose Ready to verify banner has fired, so a PR announces itself once per head.
    public var readyNotifiedOid: String? = nil
    public var parkedReason: String? = nil
    /// When the human last resumed it from parked, which bounds the round cap and the failure streak.
    public var resumedAt: Int64? = nil
    public var createdAt: Int64
    public var updatedAt: Int64

    public enum CodingKeys: String, CodingKey {
        case id
        case projectId = "project_id"
        case repoOwner = "repo_owner"
        case repoName = "repo_name"
        case number
        case url
        case title
        case isDraft = "is_draft"
        case headRef = "head_ref"
        case headOid = "head_oid"
        case headChangedAt = "head_changed_at"
        case baseRef = "base_ref"
        case state
        case round
        case reviewDecision = "review_decision"
        case checksState = "checks_state"
        case mergeable
        case labelsJSON = "labels_json"
        case paused
        case lastPolledAt = "last_polled_at"
        case lastFeedbackAt = "last_feedback_at"
        case verifiedAt = "verified_at"
        case estCostUSD = "est_cost_usd"
        case readyNotifiedOid = "ready_notified_oid"
        case parkedReason = "parked_reason"
        case resumedAt = "resumed_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public static func newId() -> String { BoardId.new() }

    public var labels: [String] {
        get { (try? JSONDecoder().decode([String].self, from: Data(labelsJSON.utf8))) ?? [] }
        set { labelsJSON = Self.encodeLabels(newValue) }
    }

    static func encodeLabels(_ labels: [String]) -> String {
        guard let data = try? JSONEncoder().encode(labels), let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }
}

public struct PRItem: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Sendable, Equatable {
    public static let databaseTableName = "pr_item"

    public var id: Int64?
    public var watchId: String
    public var githubNodeId: String
    public var kind: PRItemKind
    public var author: String?
    public var body: String
    public var path: String?
    public var line: Int?
    public var url: String?
    public var state: PRItemState
    public var verdict: PRItemVerdict?
    public var approach: String?
    public var decisionQuestion: String?
    public var decisionOptionsJSON: String?
    public var decisionAnswer: String?
    public var fixTaskId: String?
    public var followupGrade: PRFollowupGrade?
    public var followupNote: String? = nil
    public var replyBody: String?
    public var replyURL: String?
    public var round: Int
    public var createdAt: Int64
    public var updatedAt: Int64
    public var decisionNotifiedAt: Int64? = nil
    public var handledAt: Int64? = nil
    public var replyError: String? = nil
    /// Set once the item's comment is gone from GitHub, so its reply is never tried again (SPEC §13.2).
    public var replyAbandonedAt: Int64? = nil

    public enum CodingKeys: String, CodingKey {
        case id
        case watchId = "watch_id"
        case githubNodeId = "github_node_id"
        case kind
        case author
        case body
        case path
        case line
        case url
        case state
        case verdict
        case approach
        case decisionQuestion = "decision_question"
        case decisionOptionsJSON = "decision_options_json"
        case decisionAnswer = "decision_answer"
        case fixTaskId = "fix_task_id"
        case followupGrade = "followup_grade"
        case followupNote = "followup_note"
        case replyBody = "reply_body"
        case replyURL = "reply_url"
        case round
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case decisionNotifiedAt = "decision_notified_at"
        case handledAt = "handled_at"
        case replyError = "reply_error"
        case replyAbandonedAt = "reply_abandoned_at"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public var isOpenDecision: Bool { state == .open && verdict == .decision }

    public var decisionOptions: [PRDecisionOption] {
        guard let json = decisionOptionsJSON else { return [] }
        return (try? JSONDecoder().decode([PRDecisionOption].self, from: Data(json.utf8))) ?? []
    }
}

/// One choice on a decision (SPEC §13.4): choosing it answers the item as `verdict`, `fix` or
/// `answer`, and an `answer` posts `replyBody`. A bare string, the form stored before options carried
/// a verdict, decodes as a `fix`.
public struct PRDecisionOption: Codable, Sendable, Equatable, Hashable {
    public var label: String
    public var verdict: PRItemVerdict
    public var replyBody: String?

    public init(label: String, verdict: PRItemVerdict, replyBody: String? = nil) {
        self.label = label
        self.verdict = verdict
        self.replyBody = replyBody
    }

    public enum CodingKeys: String, CodingKey {
        case label
        case verdict
        case replyBody = "reply_body"
    }

    public init(from decoder: Decoder) throws {
        if let label = try? decoder.singleValueContainer().decode(String.self) {
            self.init(label: label, verdict: .fix)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            label: try container.decode(String.self, forKey: .label),
            verdict: try container.decode(PRItemVerdict.self, forKey: .verdict),
            replyBody: try container.decodeIfPresent(String.self, forKey: .replyBody)
        )
    }
}

public struct PRRound: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Sendable, Equatable {
    public static let databaseTableName = "pr_round"

    public var id: Int64?
    public var watchId: String
    public var number: Int
    public var baseHeadOid: String
    public var pushedHeadOid: String?
    public var outcome: String?
    public var startedAt: Int64
    public var endedAt: Int64?
    public var fixTaskId: String? = nil
    public var checkFailures: Int = 0
    public var reviewVerdict: PRRoundReview? = nil
    public var reviewFindings: String? = nil
    public var followupTaskId: String? = nil
    /// The round branch's tip when its follow-up check started: the head the check judged.
    public var checkedHeadOid: String? = nil
    public var reviewRequestsAt: Int64? = nil
    public var reviewRequestsJSON: String? = nil
    public var reviewRequestError: String? = nil

    public enum CodingKeys: String, CodingKey {
        case id
        case watchId = "watch_id"
        case number
        case baseHeadOid = "base_head_oid"
        case pushedHeadOid = "pushed_head_oid"
        case outcome
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case fixTaskId = "fix_task_id"
        case checkFailures = "check_failures"
        case reviewVerdict = "review_verdict"
        case reviewFindings = "review_findings"
        case followupTaskId = "followup_task_id"
        case checkedHeadOid = "checked_head_oid"
        case reviewRequestsAt = "review_requests_at"
        case reviewRequestsJSON = "review_requests_json"
        case reviewRequestError = "review_request_error"
    }

    /// The logins this round re-requested review from (SPEC §13.2).
    public var reviewRequests: [String] {
        reviewRequestsJSON.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
    }

    /// The branch a round's fixer commits on (SPEC §13.1).
    public static func branch(pullRequest number: Int, round: Int) -> String {
        "\(TaskStore.branchPrefix)pr-\(number)-r\(round)"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// One poll of a pull request, as the poller read it from GitHub.
public struct PRSnapshot: Sendable, Equatable {
    public var repoOwner: String
    public var repoName: String
    public var number: Int
    public var url: String
    public var title: String
    public var isDraft: Bool
    public var headRef: String
    public var headOid: String
    public var baseRef: String
    public var reviewDecision: String?
    /// Reviewers whose standing review approves, and those whose standing review still blocks (SPEC §13.1).
    public var approvedBy: [String]
    public var changesRequestedBy: [String]
    public var checksState: String?
    public var mergeable: String?
    public var labels: [String]
    public var items: [PRSnapshotItem]
    /// The head branch lives in another repository than the base: a fork, which follow-through parks.
    public var isCrossRepository: Bool
    /// The head repository's `owner/name`, nil when GitHub no longer has it.
    public var headRepository: String?
    /// The counted checks whose latest run on the head failed (SPEC §13.1 awaitingCI).
    public var failedChecks: [PRFailedCheck]

    public init(
        repoOwner: String, repoName: String, number: Int, url: String, title: String, isDraft: Bool = false,
        headRef: String, headOid: String, baseRef: String, reviewDecision: String? = nil,
        approvedBy: [String] = [], changesRequestedBy: [String] = [],
        checksState: String? = nil, mergeable: String? = nil, labels: [String] = [], items: [PRSnapshotItem] = [],
        isCrossRepository: Bool = false, headRepository: String? = nil, failedChecks: [PRFailedCheck] = []
    ) {
        self.repoOwner = repoOwner
        self.repoName = repoName
        self.number = number
        self.url = url
        self.title = title
        self.isDraft = isDraft
        self.headRef = headRef
        self.headOid = headOid
        self.baseRef = baseRef
        self.reviewDecision = reviewDecision
        self.approvedBy = approvedBy
        self.changesRequestedBy = changesRequestedBy
        self.checksState = checksState
        self.mergeable = mergeable
        self.labels = labels
        self.items = items
        self.isCrossRepository = isCrossRepository
        self.headRepository = headRepository
        self.failedChecks = failedChecks
    }
}

/// One failed check run or commit status, keyed by its GitHub node id, so each run becomes at most one item.
public struct PRFailedCheck: Sendable, Equatable {
    public var githubNodeId: String
    public var name: String
    public var url: String?
    public var summary: String
    /// Set only for a GitHub Actions run, whose check run id is the job id `gh run view --job` reads.
    public var jobId: Int64?
    /// The end of the job's failed-step log, once the poller has read it.
    public var logTail: String?

    public init(
        githubNodeId: String, name: String, url: String? = nil, summary: String, jobId: Int64? = nil,
        logTail: String? = nil
    ) {
        self.githubNodeId = githubNodeId
        self.name = name
        self.url = url
        self.summary = summary
        self.jobId = jobId
        self.logTail = logTail
    }

    func itemBody(head: String) -> String {
        let lead = "`\(name)` failed on \(head.prefix(7))" + (url.map { ": \($0)" } ?? ".")
        guard let logTail else { return "\(lead)\n\n\(summary)" }
        return "\(lead)\n\nThe end of its failed steps' log:\n\(logTail)"
    }
}

public struct PRSnapshotItem: Sendable, Equatable {
    public var githubNodeId: String
    public var kind: PRItemKind
    public var author: String?
    public var body: String
    public var path: String?
    public var line: Int?
    public var url: String?
    /// A resolved thread is handled; the poller may report it or simply leave it out.
    public var isResolved: Bool
    /// False for feedback too old to start triage: it updates a stored item but creates none (SPEC §13.1).
    public var opensItem: Bool

    public init(
        githubNodeId: String, kind: PRItemKind, author: String? = nil, body: String, path: String? = nil,
        line: Int? = nil, url: String? = nil, isResolved: Bool = false, opensItem: Bool = true
    ) {
        self.githubNodeId = githubNodeId
        self.kind = kind
        self.author = author
        self.body = body
        self.path = path
        self.line = line
        self.url = url
        self.isResolved = isResolved
        self.opensItem = opensItem
    }

    /// SPEC §13.1: the body of a CHANGES_REQUESTED review that has no visible text of its own.
    public static func emptyChangeRequestBody(author: String) -> String {
        "\(author) requested changes without a comment. Their requests may be in a PR conversation comment."
    }

    /// SPEC §13.1: a comment body as GitHub renders it, with every `<!-- … -->` removed. An unterminated
    /// `<!--` hides the rest of the body, as it does on GitHub.
    public static func visibleText(_ body: String) -> String {
        body.replacing(#/(?s)<!--.*?(?:-->|\z)/#, with: "")
    }
}

/// The Pull Requests page's groups, in display order. Merged and closed watches are in none.
public enum PRPageGroup: String, Sendable, CaseIterable, Equatable {
    case readyToVerify
    case needsYou
    case inProgress
    case waitingOnReviewers
    case verified
    case parked

    /// Needs you and Parked are absent from the page while empty; every other group always shows.
    public var hidesWhenEmpty: Bool { self == .needsYou || self == .parked }

    public static func of(_ state: PRWatchState, openDecisions: Int) -> PRPageGroup? {
        if state.isTerminal { return nil }
        if openDecisions > 0 { return .needsYou }
        switch state {
        case .readyToVerify: return .readyToVerify
        case .verified: return .verified
        case .parked: return .parked
        case .watching: return .waitingOnReviewers
        case .settling, .triaging, .fixing, .checking, .publishing, .awaitingCI, .stale: return .inProgress
        case .merged, .closed, .stopped: return nil
        }
    }
}

public enum PRSessionRole: String, Sendable, Equatable {
    case triage
    case fixer
    case reviewer
}

/// An active session on one of a watch's triage or fix-round tasks, which its row offers to attach to
/// (SPEC §13.4).
public struct PRListingSession: Sendable, Equatable, Identifiable {
    public var sessionId: String
    public var role: PRSessionRole

    public init(sessionId: String, role: PRSessionRole) {
        self.sessionId = sessionId
        self.role = role
    }

    public var id: String { sessionId }
}

public struct PRWatchListing: Sendable, Equatable, Identifiable {
    public var watch: PRWatch
    public var openItems: Int
    /// The open decision items, oldest first, which the Needs you group lists under the row.
    public var decisions: [PRItem]
    /// Oldest first.
    public var sessions: [PRListingSession]

    public init(watch: PRWatch, openItems: Int, decisions: [PRItem] = [], sessions: [PRListingSession] = []) {
        self.watch = watch
        self.openItems = openItems
        self.decisions = decisions
        self.sessions = sessions
    }

    public var id: String { watch.id }
    public var openDecisions: Int { decisions.count }
}

public struct PRWatchGroup: Sendable, Equatable {
    public var group: PRPageGroup
    public var listings: [PRWatchListing]

    public init(group: PRPageGroup, listings: [PRWatchListing]) {
        self.group = group
        self.listings = listings
    }
}

/// What a project's Pull Requests badge counts: PRs ready to verify plus open decisions, in projects
/// with follow-through on and on watches that are not paused (SPEC §13.4).
public struct PRBadgeCount: Sendable, Equatable {
    public var readyToVerify: Int
    public var openDecisions: Int

    public init(readyToVerify: Int = 0, openDecisions: Int = 0) {
        self.readyToVerify = readyToVerify
        self.openDecisions = openDecisions
    }

    public var total: Int { readyToVerify + openDecisions }
}

/// The moves of SPEC §13.1 decided from one poll: among watching, settling, readyToVerify and
/// verified. Leaving settling for triaging, and every later state, belongs to the follow-through driver.
public enum PRWatchTransition {
    /// How long a head with no required checks waits for CI to register any before it counts as green.
    public static let checksGraceMillis: Int64 = 5 * 60 * 1000

    /// `itemsAwaitingRound` counts open items with no verdict yet and `fix` answers to decisions not
    /// yet in a round (SPEC §13.4); any other open decision or fix still counts in `openItems`, so it
    /// keeps a PR from being ready without sending it back to triage.
    public static func next(
        from watch: PRWatch, snapshot: PRSnapshot, openItems: Int, itemsAwaitingRound: Int,
        settings: PRFollowThroughSettings, now: Int64 = .nowMillis
    ) -> PRWatchState? {
        let state = watch.state
        guard [.watching, .settling, .readyToVerify, .verified].contains(state) else { return nil }
        let labeled = settings.markVerifiedLabel.map { label in
            snapshot.labels.contains { $0.caseInsensitiveCompare(label) == .orderedSame }
        } ?? false
        let ready = (!settings.requireApproval || approved(snapshot))
            && checksGreen(snapshot.checksState, headSeenAt: watch.headChangedAt ?? watch.createdAt, now: now)
            && openItems == 0
        let target: PRWatchState = labeled ? .verified
            : itemsAwaitingRound > 0 ? .settling
            : ready ? .readyToVerify : .watching
        return target == state ? nil : target
    }

    /// GitHub's `reviewDecision` carries branch protection's required counts and code owners. Only a
    /// repository with no review requirement, where it is null, falls back to the per-reviewer standing.
    static func approved(_ snapshot: PRSnapshot) -> Bool {
        guard let decision = snapshot.reviewDecision else {
            return !snapshot.approvedBy.isEmpty && snapshot.changesRequestedBy.isEmpty
        }
        return decision == "APPROVED"
    }

    /// No checks state means nothing is required and nothing has reported, which is green only once
    /// CI has had the grace period to register a check on this head (SPEC §13.1).
    static func checksGreen(_ checks: String?, headSeenAt: Int64, now: Int64) -> Bool {
        guard let checks else { return now - headSeenAt >= checksGraceMillis }
        return checks == "SUCCESS"
    }

    static func checksFailed(_ rollup: String?) -> Bool {
        rollup == "FAILURE" || rollup == "ERROR"
    }
}
