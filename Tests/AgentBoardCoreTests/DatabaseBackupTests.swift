import Foundation
import GRDB
import XCTest
@testable import AgentBoardCore

final class DatabaseBackupTests: XCTestCase {
    private var root: URL!
    private var url: URL { root.appendingPathComponent("board.sqlite") }
    private var backups: URL { root.appendingPathComponent("backups") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-board-tests-\(UUID().uuidString)")
        let db = try AppDatabase.open(at: url)
        try ProjectStore(db).register(name: "p", repoPath: "/r", baseBranch: "main", worktreeRoot: "/w", memoryDir: nil)
        try db.writer.close()
        try removeSidecars()
    }

    /// Apple's SQLite keeps `-wal` and `-shm` after close; a copied or restored database has neither.
    private func removeSidecars() throws {
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func backupNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: backups.path).sorted()
    }

    func testDatabaseWithUnknownMigrationIsRefusedUntouched() throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { try $0.execute(sql: "INSERT INTO grdb_migrations VALUES ('from_a_newer_build')") }
        try queue.close()
        try removeSidecars()
        let before = try Data(contentsOf: url)

        XCTAssertThrowsError(try AppDatabase.open(at: url, build: BuildIdentity(version: "9.0.0", build: "1", commit: nil))) {
            XCTAssertEqual(
                $0 as? AppDatabaseError,
                .writtenByNewerBuild(database: url, unknownMigrations: ["from_a_newer_build"], newestBackup: nil)
            )
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))
    }

    func testNewBuildBacksUpOnceAndKeepsThree() throws {
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let seeded = ["agentboard-20200101-000001-0.1.0.sqlite", "agentboard-20200101-000002-0.1.0.sqlite", "agentboard-20200101-000003-0.1.0.sqlite"]
        for name in seeded {
            FileManager.default.createFile(atPath: backups.appendingPathComponent(name).path, contents: Data())
        }
        let pages = try DatabaseQueue(path: url.path).read { try Int.fetchOne($0, sql: "PRAGMA page_count") }
        let build = BuildIdentity(version: "0.2.0", build: "7", commit: "abc")

        _ = try AppDatabase.open(at: url, build: build)
        let after = try backupNames()
        XCTAssertEqual(Array(after.prefix(2)), Array(seeded.suffix(2)))
        let taken = try XCTUnwrap(after.first { !seeded.contains($0) && $0.hasSuffix("-unknown.sqlite") })
        XCTAssertEqual(Set(after), Set(seeded.suffix(2) + [taken, "last-opened-build.json"]))
        let inspected = root.appendingPathComponent("inspected.sqlite")
        try FileManager.default.copyItem(at: backups.appendingPathComponent(taken), to: inspected)
        let copy = try DatabaseQueue(path: inspected.path)
        XCTAssertEqual(try copy.read { try Int.fetchOne($0, sql: "PRAGMA page_count") }, pages)
        XCTAssertEqual(try copy.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM project") }, 1)
        try copy.close()

        _ = try AppDatabase.open(at: url, build: build)
        XCTAssertEqual(try backupNames(), after)
    }

    func testBackupStampedBeforeExistingOnesIsNotPruned() throws {
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let seeded = ["agentboard-29990101-000001-0.1.0.sqlite", "agentboard-29990101-000002-0.1.0.sqlite", "agentboard-29990101-000003-0.1.0.sqlite"]
        for name in seeded {
            FileManager.default.createFile(atPath: backups.appendingPathComponent(name).path, contents: Data())
        }

        _ = try AppDatabase.open(at: url, build: BuildIdentity(version: "0.2.0", build: "7", commit: "abc"))
        let after = try backupNames().filter { $0.hasSuffix(".sqlite") }
        XCTAssertEqual(after.count, 3)
        XCTAssertEqual(Array(after.suffix(2)), Array(seeded.suffix(2)))
        XCTAssertTrue(after[0].hasSuffix("-unknown.sqlite"))
    }
}
