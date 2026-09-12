import Foundation

/// One quota window as `/usage` reports it.
public struct AccountUsageWindow: Sendable, Equatable {
    /// Clamped to 0...100; the API has been seen to report values outside it.
    public let percent: Int
    public let resetsAt: Date?

    public init(percent: Int, resetsAt: Date?) {
        self.percent = min(100, max(0, percent))
        self.resetsAt = resetsAt
    }
}

/// Account headroom read from the `cachedUsageUtilization` block Claude Code keeps in
/// `~/.claude.json`. That block is a **cache**, refreshed when a session talks to the API, so it
/// can be hours old — every reading carries its age and callers must show it rather than imply
/// the number is live.
public struct AccountUsageSnapshot: Sendable, Equatable {
    public let fiveHour: AccountUsageWindow?
    public let sevenDay: AccountUsageWindow?
    /// Nil when the block carried no `fetchedAtMs`: the age is unknown, not zero.
    public let fetchedAt: Date?

    /// Past this, the fallback refresh is allowed to run.
    public static let staleAfter: TimeInterval = 30 * 60

    public init(fiveHour: AccountUsageWindow?, sevenDay: AccountUsageWindow?, fetchedAt: Date?) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.fetchedAt = fetchedAt
    }

    public func age(at now: Date = .now) -> TimeInterval? {
        fetchedAt.map { max(0, now.timeIntervalSince($0)) }
    }

    /// An unknown age counts as stale — freshness has to be proven, not assumed.
    public func isStale(at now: Date = .now, threshold: TimeInterval = AccountUsageSnapshot.staleAfter) -> Bool {
        guard let age = age(at: now) else { return true }
        return age > threshold
    }
}

public enum AccountUsageReader {
    public static var defaultConfigURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json")
    }

    /// Nil for an unreadable file, unparsable JSON, or a config with no usage block. Never throws.
    public static func read(configAt url: URL = defaultConfigURL) -> AccountUsageSnapshot? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cached = root["cachedUsageUtilization"] as? [String: Any],
              let utilization = cached["utilization"] as? [String: Any]
        else { return nil }

        let fetchedAt = (cached["fetchedAtMs"] as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }

        return AccountUsageSnapshot(
            fiveHour: window(utilization["five_hour"]),
            sevenDay: window(utilization["seven_day"]),
            fetchedAt: fetchedAt
        )
    }

    private static func window(_ raw: Any?) -> AccountUsageWindow? {
        guard let raw = raw as? [String: Any] else { return nil }
        guard let percent = (raw["utilization"] as? NSNumber)?.doubleValue else { return nil }
        return AccountUsageWindow(
            percent: Int(percent.rounded()),
            resetsAt: (raw["resets_at"] as? String).flatMap(parseTimestamp)
        )
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// The API writes microsecond precision, which `ISO8601DateFormatter` rejects, so the
    /// fractional part is trimmed to milliseconds before the second attempt.
    static func parseTimestamp(_ value: String) -> Date? {
        if let date = fractionalFormatter.date(from: value) { return date }
        if let date = plainFormatter.date(from: value) { return date }
        guard let dot = value.firstIndex(of: ".") else { return nil }
        let afterDot = value.index(after: dot)
        let digits = value[afterDot...].prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let tail = String(value[value.index(afterDot, offsetBy: digits.count)...])
        let head = String(value[..<afterDot])
        return fractionalFormatter.date(from: head + digits.prefix(3) + tail)
            ?? plainFormatter.date(from: String(value[..<dot]) + tail)
    }
}
