import Foundation
import GRDB

/// The build opening the database, read from the main bundle's Info.plist. A key the bundle lacks
/// is nil and equals only another nil, so relaunching one `bundle.sh` build is not a new build (SPEC §4.1).
public struct BuildIdentity: Codable, Equatable, Sendable {
    public var version: String?
    public var build: String?
    public var commit: String?

    public init(version: String?, build: String?, commit: String?) {
        self.version = version
        self.build = build
        self.commit = commit
    }

    public init(infoDictionary: [String: Any]?) {
        self.init(
            version: infoDictionary?["CFBundleShortVersionString"] as? String,
            build: infoDictionary?["CFBundleVersion"] as? String,
            commit: infoDictionary?["AgentBoardCommit"] as? String
        )
    }

    var backupLabel: String {
        guard let version else { return "unknown" }
        guard let build, Int(build) != nil else { return version }
        return "\(version)+\(build)"
    }
}

public enum AppDatabaseError: Error, Equatable, LocalizedError {
    /// The database has applied migrations this build does not register (SPEC §4.1).
    case writtenByNewerBuild(database: URL, unknownMigrations: [String], newestBackup: URL?)
    case backupIncomplete(database: URL, expectedPages: Int, copiedPages: Int)

    public var errorDescription: String? {
        switch self {
        case let .writtenByNewerBuild(database, unknown, _):
            "\(database.path) was last used by a newer Agent Board: it has migrations this build does not know (\(unknown.joined(separator: ", ")))."
        case let .backupIncomplete(database, expected, copied):
            "The backup of \(database.path) copied \(copied) of \(expected) pages, so it was discarded and the database was not migrated."
        }
    }

    public var restoreCommand: String? {
        guard case let .writtenByNewerBuild(database, _, backup?) = self else { return nil }
        return "sqlite3 '\(database.path)' \".restore '\(backup.path)'\""
    }
}

/// `backups/` beside the database: timestamped copies plus a record of the last build that opened it (SPEC §4.1).
struct DatabaseBackups {
    static let kept = 3

    let database: URL
    var directory: URL { database.deletingLastPathComponent().appendingPathComponent("backups") }
    private var recordURL: URL { directory.appendingPathComponent("last-opened-build.json") }
    private let fileManager = FileManager.default

    /// Ascending by name, which is by time: the timestamp leads.
    func list() -> [URL] {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.wholeMatch(of: #/agentboard-\d{8}-\d{6}-.+\.sqlite/#) != nil }
            .sorted()
            .map { directory.appendingPathComponent($0) }
    }

    func newest() -> URL? { list().last }

    func lastOpenedBuild() -> BuildIdentity? {
        guard let data = try? Data(contentsOf: recordURL) else { return nil }
        return try? JSONDecoder().decode(BuildIdentity.self, from: data)
    }

    func record(_ build: BuildIdentity) throws {
        guard lastOpenedBuild() != build else { return }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(build).write(to: recordURL, options: .atomic)
    }

    /// Copies `source` under a temporary name and renames it only once its page count matches, so an
    /// interrupted backup never carries the name that pruning and restoring look for.
    @discardableResult
    func take(from source: some DatabaseReader, label: String, now: Date = Date()) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = Set(list().map(\.lastPathComponent))
        var instant = now
        var stamp = Self.stamp(instant)
        while existing.contains(where: { $0.hasPrefix("agentboard-\(stamp)-") }) {
            instant += 1
            stamp = Self.stamp(instant)
        }
        let target = directory.appendingPathComponent("agentboard-\(stamp)-\(label).sqlite")
        let partial = directory.appendingPathComponent(".agentboard-\(stamp).partial")
        removePartials()
        do {
            let destination = try DatabaseQueue(path: partial.path)
            try source.backup(to: destination)
            let expected = try source.read { try Int.fetchOne($0, sql: "PRAGMA page_count") } ?? 0
            let copied = try destination.read { try Int.fetchOne($0, sql: "PRAGMA page_count") } ?? 0
            try destination.close()
            guard copied == expected else {
                throw AppDatabaseError.backupIncomplete(database: database, expectedPages: expected, copiedPages: copied)
            }
            try fileManager.moveItem(at: partial, to: target)
            removePartials()
        } catch {
            removePartials()
            throw error
        }
        for old in list().dropLast(Self.kept) {
            try? fileManager.removeItem(at: old)
        }
        return target
    }

    private func removePartials() {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(".agentboard-") && name.contains(".partial") {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
