import Foundation
import GRDB

public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public var reader: any DatabaseReader { writer }

    private init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    public static func open(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.journalMode = .wal
        return try AppDatabase(DatabasePool(path: url.path, configuration: configuration))
    }

    public static func inMemory() throws -> AppDatabase {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        return try AppDatabase(DatabaseQueue(configuration: configuration))
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: Schema.v1)
        }
        migrator.registerMigration("task_model") { db in
            try db.execute(sql: "ALTER TABLE task ADD COLUMN model TEXT")
        }
        migrator.registerMigration("approval") { db in
            try db.execute(sql: Schema.approval)
        }
        migrator.registerMigration("note_section_written_by") { db in
            try db.execute(sql: "ALTER TABLE note_section ADD COLUMN written_by TEXT")
        }
        migrator.registerMigration("task_archived_at") { db in
            try db.execute(sql: "ALTER TABLE task ADD COLUMN archived_at INTEGER")
            try db.execute(sql: "CREATE INDEX task_project_archived ON task(project_id, archived_at)")
        }
        migrator.registerMigration("task_done_at") { db in
            try db.execute(sql: "ALTER TABLE task ADD COLUMN done_at INTEGER")
            try db.execute(sql: "ALTER TABLE task ADD COLUMN unarchived_at INTEGER")
            try db.execute(sql: "CREATE INDEX task_project_done_at ON task(project_id, done_at)")
            // `updated_at` is the closest stamp rows written before this migration have; without it
            // every task already sitting in done would read as "entered done never" and outlive afterDays.
            try db.execute(sql: "UPDATE task SET done_at = updated_at WHERE column_name = 'done'")
        }
        return migrator
    }
}

extension Int64 {
    public static var nowMillis: Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    public var asDate: Date {
        Date(timeIntervalSince1970: Double(self) / 1000)
    }
}

public enum BoardId {
    public static func new() -> String {
        UUID().uuidString.lowercased()
    }
}
