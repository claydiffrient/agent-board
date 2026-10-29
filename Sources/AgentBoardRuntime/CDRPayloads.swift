import Foundation

/// The CDR watcher daemon's `GET /status`, reduced to what the Reviews screen shows. Every field decodes
/// leniently: CDR's shapes change, so a missing or retyped field reads as nil, never a failed decode (SPEC §13.7).
public struct CDRStatus: Decodable, Equatable, Sendable {
    public var pid: Int?
    public var version: String?
    public var startedAt: String?
    public var polling: CDRPolling?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CDRKey.self)
        pid = c.lenient("pid")
        version = c.lenient("version")
        startedAt = c.lenient("startedAt")
        polling = c.lenient("polling")
    }
}

/// `loop.snapshot()` in CDR's `watcher/loop.mjs`.
public struct CDRPolling: Decodable, Equatable, Sendable {
    public var running: [CDRQueueEntry]
    public var queued: [CDRQueueEntry]
    public var waiting: [CDRQueueEntry]
    public var retrying: [CDRQueueEntry]
    public var parked: [CDRQueueEntry]
    public var denied: [CDRQueueEntry]
    public var reviewed: [CDRQueueEntry]
    /// CDR sends `false` when nothing holds the loop, which reads as nil here.
    public var paused: CDRPause?
    public var budget: CDRBudget?
    public var concurrency: CDRConcurrency?
    public var power: CDRPower?
    public var lastPoll: CDRPoll?
    public var nextPollAt: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CDRKey.self)
        running = c.list("running")
        queued = c.list("queued")
        waiting = c.list("waiting")
        retrying = c.list("retrying")
        parked = c.list("parked")
        denied = c.list("denied")
        reviewed = c.list("reviewed")
        paused = c.lenient("paused")
        budget = c.lenient("budget")
        concurrency = c.lenient("concurrency")
        power = c.lenient("power")
        lastPoll = c.lenient("lastPoll")
        nextPollAt = c.lenient("nextPollAt")
    }
}

/// One review request, from `entry(c)` in `watcher/loop.mjs` plus the fields each list adds to it.
public struct CDRQueueEntry: Decodable, Equatable, Sendable {
    public var request: Int?
    public var repo: String?
    public var pr: Int?
    public var title: String?
    public var url: String?
    public var requestedAt: String?
    public var startedAt: String?
    public var dueAt: String?
    /// Why a due request is not running: `pause`, `runner`, `poll`, `battery`, `charge`, `budget` or `concurrency`.
    public var blockedBy: String?
    public var attempts: Int?
    public var lastError: String?
    public var retryAt: String?
    public var rule: String?
    public var match: String?
    public var reviewId: Int?
    /// A running review's `progress.phase`: `reviewing`, `requested lenses`, `triage` or `posting`.
    public var phase: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CDRKey.self)
        request = c.lenient("request")
        repo = c.lenient("repo")
        pr = c.lenient("pr")
        title = c.lenient("title")
        url = c.lenient("url")
        requestedAt = c.lenient("requestedAt")
        startedAt = c.lenient("startedAt")
        dueAt = c.lenient("dueAt")
        blockedBy = c.lenient("blockedBy")
        attempts = c.lenient("attempts")
        lastError = c.lenient("lastError")
        retryAt = c.lenient("retryAt")
        rule = c.lenient("rule")
        match = c.lenient("match")
        reviewId = c.lenient("reviewId")
        phase = c.lenient("progress").flatMap { (p: CDRProgress) in p.phase }
    }
}

private struct CDRProgress: Decodable {
    var phase: String?

    init(from decoder: Decoder) throws {
        phase = try decoder.container(keyedBy: CDRKey.self).lenient("phase")
    }
}

/// A usage limit holding the loop.
public struct CDRPause: Decodable, Equatable, Sendable {
    public var since: String?
    public var until: String?
    public var detail: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CDRKey.self)
        since = c.lenient("since")
        until = c.lenient("until")
        detail = c.lenient("detail")
    }
}

/// Review starts in the rolling 24 hours against the daily limit.
public struct CDRBudget: Decodable, Equatable, Sendable {
    public var limit: Int?
    public var used: Int?
    public var exhausted: Bool?
    public var freesAt: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CDRKey.self)
        limit = c.lenient("limit")
        used = c.lenient("used")
        exhausted = c.lenient("exhausted")
        freesAt = c.lenient("freesAt")
    }
}

public struct CDRConcurrency: Decodable, Equatable, Sendable {
    public var limit: Int?
    public var running: Int?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CDRKey.self)
        limit = c.lenient("limit")
        running = c.lenient("running")
    }
}

public struct CDRPower: Decodable, Equatable, Sendable {
    public var ac: Bool?
    public var source: String?
    public var percent: Int?
    /// `battery` or `charge` while power holds due requests, nil otherwise.
    public var hold: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CDRKey.self)
        ac = c.lenient("ac")
        source = c.lenient("source")
        percent = c.lenient("percent")
        hold = c.lenient("hold")
    }
}

public struct CDRPoll: Decodable, Equatable, Sendable {
    public var at: String?
    public var ok: Bool?
    public var why: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CDRKey.self)
        at = c.lenient("at")
        ok = c.lenient("ok")
        why = c.lenient("why")
    }
}

/// One entry of the review server's `GET /api/targets`: a target row from `db.targetSummary` in CDR's
/// `server/db.mjs`, with its reviews oldest first.
public struct CDRTarget: Decodable, Equatable, Sendable {
    public var id: Int
    public var owner: String?
    public var repo: String?
    public var pr: Int?
    public var branch: String?
    public var title: String?
    public var url: String?
    /// `open`, `closed` or `merged`.
    public var prState: String?
    public var reviews: [CDRReview]
    public var queued: Int?
    public var posted: Int?
    public var toPost: Int?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CDRKey.self)
        id = try c.decode(Int.self, forKey: CDRKey("id"))
        owner = c.lenient("owner")
        repo = c.lenient("repo")
        pr = c.lenient("pr")
        branch = c.lenient("branch")
        title = c.lenient("title")
        url = c.lenient("url")
        prState = c.lenient("pr_state")
        reviews = c.list("reviews")
        queued = c.lenient("queued")
        posted = c.lenient("posted")
        toPost = c.lenient("to_post")
    }

    /// The worklist page, which needs no token, so it can open in the browser.
    public var pagePath: String { "/t/\(id)" }
}

public struct CDRReview: Decodable, Equatable, Sendable {
    public var id: Int?
    /// SQLite UTC text, `YYYY-MM-DD HH:MM:SS`; `startedDate` parses it.
    public var startedAt: String?
    public var finishedAt: String?
    public var verdict: String?
    /// `manual` for a `/cd:review` Clay ran, `cdr` for one the watcher ran.
    public var source: String?
    public var findings: Int?
    public var lensesRan: Int?
    public var lensesFailed: Int?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CDRKey.self)
        id = c.lenient("id")
        startedAt = c.lenient("started_at")
        finishedAt = c.lenient("finished_at")
        verdict = c.lenient("verdict")
        source = c.lenient("source")
        findings = c.lenient("findings")
        lensesRan = c.lenient("lenses_ran")
        lensesFailed = c.lenient("lenses_failed")
    }

    public var startedDate: Date? { startedAt.flatMap(CDRTime.parse) }
    public var finishedDate: Date? { finishedAt.flatMap(CDRTime.parse) }
}

/// CDR writes two time formats: ISO 8601 from the watcher, SQLite's UTC `datetime('now')` from the database.
public enum CDRTime {
    public static func parse(_ text: String) -> Date? {
        sqlite.date(from: text) ?? fractional.date(from: text) ?? whole.date(from: text)
    }

    private static let sqlite: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let whole = ISO8601DateFormatter()
}

struct CDRKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

private struct Lossy<T: Decodable>: Decodable {
    var value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

extension KeyedDecodingContainer where K == CDRKey {
    func lenient<T: Decodable>(_ key: String) -> T? {
        try? decodeIfPresent(T.self, forKey: CDRKey(key))
    }

    /// One malformed element drops that element, not the list.
    func list<T: Decodable>(_ key: String) -> [T] {
        (lenient(key) as [Lossy<T>]?)?.compactMap(\.value) ?? []
    }
}
