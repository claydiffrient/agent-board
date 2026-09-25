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
            XCTAssertEqual(grant.first { $0.name == "project_id" }?.isNotNull, false, "the Coordinator's grant has no project")
            XCTAssertTrue(grant.contains { $0.name == "created_at" && $0.isNotNull })

            let session = try db.columns(in: "agent_session").map(\.name)
            XCTAssertTrue(session.contains("model"))
            XCTAssertTrue(session.contains("last_tool"))
            XCTAssertTrue(session.contains("stop_reason"))

            let taskColumns = try db.columns(in: "task").map(\.name)
            XCTAssertTrue(taskColumns.contains("column_name"))

            let rosterColumns = try db.columns(in: "roster_agent").map(\.name)
            XCTAssertFalse(rosterColumns.contains("project_id"), "the roster is cross-project")
            XCTAssertEqual(
                rosterColumns,
                ["id", "name", "role", "system_prompt", "model", "disallowed_tools", "enabled", "created_at", "updated_at"]
            )
            XCTAssertEqual(
                try db.columns(in: "project_roster_agent").map(\.name),
                ["project_id", "roster_agent_id", "ordering"]
            )
        }
    }

    /// SQLite cannot drop NOT NULL in place, so the migration rebuilds both tables; nothing already in
    /// them may be lost, including a message's link to the report that delivered it.
    func testTheCoordinatorMigrationKeepsEveryRowAndTiesANullProjectToTheCoordinatorScope() throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: configuration)
        try AppDatabase.migrator.migrate(queue, upTo: "comment_delivery")
        try queue.write { db in
            for id in ["p1", "p2"] {
                try db.execute(
                    sql: "INSERT INTO project (id, name, repo_path, worktree_root, settings_json, created_at) VALUES (?, ?, ?, '/w', '{}', 0)",
                    arguments: [id, id, "/repo/\(id)"]
                )
            }
            try db.execute(sql: "INSERT INTO token_grant (token, project_id, scope, created_at) VALUES ('t1', 'p1', 'orchestrator', 5)")
            try db.execute(sql: "INSERT INTO report (id, project_id, kind, body, created_at) VALUES (7, 'p2', 'message', 'hello', 6)")
            try db.execute(sql: "INSERT INTO message (from_project_id, to_project_id, body, created_at, report_id) VALUES ('p1', 'p2', 'hello', 6, 7)")
        }

        try AppDatabase.migrator.migrate(queue)

        try queue.write { db in
            XCTAssertEqual(try TokenGrant.fetchOne(db, key: "t1")?.projectId, "p1")
            XCTAssertEqual(try Report.fetchOne(db, key: 7)?.body, "hello")
            XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT r.id FROM message m JOIN report r ON r.id = m.report_id"), 7)
            XCTAssertEqual(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count, 0)
            XCTAssertTrue(try db.indexes(on: "report").map(\.name).contains("report_project_consumed"))
            XCTAssertTrue(try db.indexes(on: "token_grant").map(\.name).contains("token_grant_session"))

            try db.execute(sql: "INSERT INTO token_grant (token, scope, created_at) VALUES ('c', 'coordinator', 0)")
            XCTAssertThrowsError(
                try db.execute(sql: "INSERT INTO token_grant (token, scope, created_at) VALUES ('w', 'worker', 0)"),
                "only the Coordinator's grant may have no project"
            )
            XCTAssertThrowsError(
                try db.execute(sql: "INSERT INTO token_grant (token, project_id, scope, created_at) VALUES ('c2', 'p1', 'coordinator', 0)"),
                "the Coordinator's grant may not name a project"
            )
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
