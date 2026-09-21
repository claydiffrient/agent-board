import Foundation

/// A `major.minor.patch` version, ordered numerically. `0.10.0` is above `0.9.0` here and below it
/// under string comparison, which is the whole reason this is a type rather than a `String`.
public struct ReleaseVersion: Equatable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// One to three dot-separated non-negative integers, with an optional `v` prefix. Missing
    /// components are zero, so `CFBundleShortVersionString`'s legal `0.1` reads as `0.1.0`.
    /// Pre-release and build suffixes are rejected rather than ordered by a rule nobody wrote down.
    public init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespaces)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber),
                  let value = Int(part)
            else { return nil }
            numbers.append(value)
        }
        major = numbers[0]
        minor = numbers.count > 1 ? numbers[1] : 0
        patch = numbers.count > 2 ? numbers[2] : 0
    }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}

/// One release: its version, the day it shipped if the author recorded one, and the Markdown
/// written under the heading.
public struct ReleaseNotesEntry: Equatable, Sendable {
    public let version: ReleaseVersion
    public let date: Date?
    public let body: String

    public init(version: ReleaseVersion, date: Date? = nil, body: String) {
        self.version = version
        self.date = date
        self.body = body
    }
}

/// Why `RELEASES.md` could not be read as releases. Every case names the line so a mistyped heading
/// is a sentence a user can forward, not an empty window.
public enum ReleaseNotesParseError: Error, Equatable, CustomStringConvertible {
    case noReleases
    case unreadableHeading(line: Int, heading: String)
    case unreadableDate(line: Int, version: String, date: String)
    case duplicateVersion(line: Int, version: String)
    case emptyBody(line: Int, version: String)

    public var description: String {
        switch self {
        case .noReleases:
            return "RELEASES.md has no release headings. A release starts with '## <version>'."
        case let .unreadableHeading(line, heading):
            return "RELEASES.md line \(line): '## \(heading)' is not '## <version>' or "
                + "'## <version> — YYYY-MM-DD'."
        case let .unreadableDate(line, version, date):
            return "RELEASES.md line \(line): release \(version) has the date '\(date)', "
                + "which is not a calendar day written YYYY-MM-DD."
        case let .duplicateVersion(line, version):
            return "RELEASES.md line \(line): release \(version) appears twice."
        case let .emptyBody(line, version):
            return "RELEASES.md line \(line): release \(version) has no notes under it."
        }
    }
}

/// Reads the hand-written `RELEASES.md` into entries. Pure: a string in, entries out, no file
/// access — loading the file is the app target's job.
///
/// The format is one `## <version>` heading per release, optionally ` — YYYY-MM-DD`, with free
/// Markdown beneath. Anything before the first heading is a title and preamble and is ignored.
/// A heading that is not a version is an error rather than an `Unreleased` section, because every
/// entry has to be comparable against the running version to decide what a user has already seen.
public enum ReleaseNotesParser {
    public static func parse(_ markdown: String) throws -> [ReleaseNotesEntry] {
        var entries: [ReleaseNotesEntry] = []
        var seen: Set<ReleaseVersion> = []
        var open: (version: ReleaseVersion, date: Date?, line: Int, body: [String])?
        var inFence = false

        func close(_ pending: (version: ReleaseVersion, date: Date?, line: Int, body: [String])) throws {
            let body = trimBlankEdges(pending.body).joined(separator: "\n")
            guard !body.isEmpty else {
                throw ReleaseNotesParseError.emptyBody(line: pending.line, version: "\(pending.version)")
            }
            entries.append(ReleaseNotesEntry(version: pending.version, date: pending.date, body: body))
        }

        for (index, line) in markdown.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let number = index + 1
            let text = String(line)
            if text.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
            }
            guard !inFence, let heading = releaseHeading(text) else {
                if open != nil { open!.body.append(text) }
                continue
            }
            let (version, date) = try parseHeading(heading, line: number)
            guard !seen.contains(version) else {
                throw ReleaseNotesParseError.duplicateVersion(line: number, version: "\(version)")
            }
            seen.insert(version)
            if let pending = open { try close(pending) }
            open = (version, date, number, [])
        }
        if let pending = open { try close(pending) }
        guard !entries.isEmpty else { throw ReleaseNotesParseError.noReleases }
        return entries.sorted { $0.version > $1.version }
    }

    /// The heading text of a `## ` line, or nil. `###` and deeper belong to a release's body.
    private static func releaseHeading(_ line: String) -> String? {
        guard line.hasPrefix("## "), !line.hasPrefix("###") else { return nil }
        return String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
    }

    private static func parseHeading(
        _ heading: String, line: Int
    ) throws -> (ReleaseVersion, Date?) {
        var versionText = heading
        var dateText: String?
        for separator in [" — ", " – ", " - "] {
            guard let range = heading.range(of: separator) else { continue }
            versionText = String(heading[heading.startIndex..<range.lowerBound])
            dateText = String(heading[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            break
        }
        guard let version = ReleaseVersion(versionText) else {
            throw ReleaseNotesParseError.unreadableHeading(line: line, heading: heading)
        }
        guard let dateText else { return (version, nil) }
        guard let date = calendarDay(dateText) else {
            throw ReleaseNotesParseError.unreadableDate(
                line: line, version: "\(version)", date: dateText
            )
        }
        return (version, date)
    }

    /// `YYYY-MM-DD` at noon UTC, so formatting the instant in any real time zone still names the
    /// day the author wrote.
    static func calendarDay(_ text: String) -> Date? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(identifier: "UTC") else { return nil }
        calendar.timeZone = utc
        let components = DateComponents(year: year, month: month, day: day, hour: 12)
        guard let date = calendar.date(from: components),
              calendar.component(.month, from: date) == month,
              calendar.component(.day, from: date) == day
        else { return nil }
        return date
    }

    private static func trimBlankEdges(_ lines: [String]) -> [String] {
        var lines = lines
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        return lines
    }
}
