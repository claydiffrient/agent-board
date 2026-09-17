import Foundation
import GRDB
import XCTest
@testable import AgentBoardCore

final class TaskCommitStoreTests: XCTestCase {
    private func store() throws -> TaskCommitStore { TaskCommitStore(try AppDatabase.inMemory()) }

    func testTheMigrationCreatesTheTableAndItsShaIndex() throws {
        let db = try AppDatabase.inMemory()
        try db.reader.read { db in
            XCTAssertEqual(try db.columns(in: "task_commit").map(\.name), ["task_id", "sha"])
            XCTAssertTrue(try db.columns(in: "task_commit").allSatisfy(\.isNotNull))
            XCTAssertEqual(try db.indexes(on: "task_commit").first { !$0.isUnique }?.columns, ["sha"])
        }
    }

    func testRecordingTheSameCommitTwiceKeepsOneRow() throws {
        let s = try store()
        try s.record(taskId: "alpha", sha: "a")
        try s.record(taskId: "alpha", sha: "a")
        XCTAssertEqual(try s.shas(taskId: "alpha"), ["a"])
    }

    func testLookupReturnsOnlyShasThatHaveARow() throws {
        let s = try store()
        try s.record([(taskId: "alpha", sha: "a1"), (taskId: "beta", sha: "b1")])
        XCTAssertEqual(
            try s.taskIds(forShas: ["a1", "b1", "unrecorded"]),
            ["a1": "alpha", "b1": "beta"]
        )
        XCTAssertEqual(try s.taskIds(forShas: []), [:])
    }

    /// SQLite refuses more than 999 bound parameters in one statement, and a long-lived shared
    /// branch carries more commits than that.
    func testALookupWiderThanSQLitesParameterLimitStillResolvesEveryCommit() throws {
        let s = try store()
        let shas = (0..<1500).map { "sha-\($0)" }
        try s.record(shas.map { (taskId: "alpha", sha: $0) })
        XCTAssertEqual(try s.taskIds(forShas: shas).count, 1500)
    }
}
