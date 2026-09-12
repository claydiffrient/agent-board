import Foundation
import GRDB
import XCTest
@testable import AgentBoardCore

final class SchemaTests: XCTestCase {
    func testMigrationCreatesEverySpecTable() throws {
        let db = try AppDatabase.inMemory()
        let names = try db.reader.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        for table in Schema.tables {
            XCTAssertTrue(names.contains(table), "missing table \(table)")
        }
        XCTAssertTrue(try db.reader.read { try $0.tableExists("note_fts") })
    }

    func testSchemaDeviationsArePresent() throws {
        let db = try AppDatabase.inMemory()
        try db.reader.read { db in
            let grant = try db.columns(in: "token_grant")
            XCTAssertEqual(grant.first { $0.name == "session_id" }?.isNotNull, false)
            XCTAssertTrue(grant.contains { $0.name == "project_id" && $0.isNotNull })
            XCTAssertTrue(grant.contains { $0.name == "created_at" && $0.isNotNull })

            let session = try db.columns(in: "agent_session").map(\.name)
            XCTAssertTrue(session.contains("model"))
            XCTAssertTrue(session.contains("last_tool"))
            XCTAssertTrue(session.contains("stop_reason"))

            let taskColumns = try db.columns(in: "task").map(\.name)
            XCTAssertTrue(taskColumns.contains("column_name"))
        }
    }

    func testForeignKeysAreEnforced() throws {
        let db = try AppDatabase.inMemory()
        XCTAssertThrowsError(try db.writer.write { db in
            try db.execute(
                sql: "INSERT INTO task (id, project_id, title, column_name, ordering, origin, created_at, updated_at) VALUES ('t', 'missing', 'x', 'backlog', 1, 'human', 0, 0)"
            )
        })
    }

    func testOpenAtPathCreatesParentDirectoryAndUsesWAL() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-board-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("nested/board.sqlite")
        let db = try AppDatabase.open(at: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let mode = try db.reader.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }
        XCTAssertEqual(mode, "wal")
        XCTAssertNotNil(try ProjectStore(db).list())
    }

    func testMigratorIsIdempotentAcrossReopen() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-board-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("board.sqlite")
        let first = try AppDatabase.open(at: url)
        try ProjectStore(first).register(name: "p", repoPath: "/r", baseBranch: "main", worktreeRoot: "/w", memoryDir: nil)
        let second = try AppDatabase.open(at: url)
        XCTAssertEqual(try ProjectStore(second).list().count, 1)
    }
}
