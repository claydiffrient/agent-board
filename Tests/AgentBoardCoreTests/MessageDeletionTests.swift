import Foundation
import GRDB
import XCTest
@testable import AgentBoardCore

final class MessageDeletionTests: XCTestCase {
    func testDeleteClearReadAndTheSweepRemoveMessagesForBothProjects() throws {
        let f = try Fixture.make()
        let beta = try f.projects.register(
            name: "Beta", repoPath: "/tmp/beta-\(UUID().uuidString)", baseBranch: "main",
            worktreeRoot: "/tmp/beta-worktrees", memoryDir: nil
        )
        func send(_ body: String) throws -> (message: Message, report: Report) {
            try f.messages.send(fromProjectId: f.project.id, fromSessionId: nil, toProjectId: beta.id, body: body)
        }
        func consume(_ report: Report, daysAgo: Int64) throws {
            let at = Int64.nowMillis - daysAgo * ArchiveSweep.millisPerDay
            try f.db.writer.write { db in
                try db.execute(sql: "UPDATE report SET consumed_at = ? WHERE id = ?", arguments: [at, report.id])
            }
        }
        func bodies(_ projectId: String) throws -> Set<String> {
            Set(try f.messages.conversation(projectId: projectId).map(\.body))
        }
        func reportExists(_ report: Report) throws -> Bool {
            try f.reports.get(try XCTUnwrap(report.id)) != nil
        }

        let unread = try send("unread")
        try f.messages.delete(id: try XCTUnwrap(unread.message.id))
        XCTAssertEqual(try bodies(f.project.id), [])
        XCTAssertEqual(try bodies(beta.id), [])
        XCTAssertFalse(try reportExists(unread.report), "an unread message's report must go with it")

        let read = try send("read")
        let stillUnread = try send("still unread")
        try consume(read.report, daysAgo: 0)
        XCTAssertEqual(try f.messages.deleteRead(projectId: f.project.id), 1)
        XCTAssertEqual(try bodies(f.project.id), ["still unread"])
        XCTAssertEqual(try bodies(beta.id), ["still unread"])
        XCTAssertFalse(try reportExists(read.report))
        XCTAssertTrue(try reportExists(stillUnread.report))

        let old = try send("consumed 8 days ago")
        let recent = try send("consumed 1 day ago")
        try consume(old.report, daysAgo: 8)
        try consume(recent.report, daysAgo: 1)
        XCTAssertEqual(try f.messages.deleteExpired(), 1)
        XCTAssertEqual(try bodies(beta.id), ["still unread", "consumed 1 day ago"])
    }
}
