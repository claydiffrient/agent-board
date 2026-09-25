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

    /// SPEC §9.4: the same sweep deletes a request closed more than 7 days ago, and never an open one.
    func testTheSweepDeletesARequestClosedEightDaysAgoAndKeepsAnOpenOne() throws {
        let f = try Fixture.make()
        let requests = RequestStore(f.db)
        let eightDaysAgo = Int64.nowMillis - 8 * ArchiveSweep.millisPerDay
        let open = try requests.send(toProjectId: f.project.id, body: "still wanted", planNoteId: nil)
        let closed = try requests.send(toProjectId: f.project.id, body: "declined", planNoteId: "plan-1")
        let reply = try requests.reply(
            requestId: try XCTUnwrap(closed.request.id), fromProjectId: f.project.id, state: .declined, body: "no capacity"
        )
        try f.db.writer.write { db in
            try db.execute(sql: "UPDATE coordinator_request SET created_at = ?", arguments: [eightDaysAgo])
            try db.execute(sql: "UPDATE coordinator_request SET closed_at = ? WHERE id = ?", arguments: [eightDaysAgo, closed.request.id])
        }

        XCTAssertEqual(try requests.deleteExpired(), 1)
        XCTAssertEqual(try requests.ledger().compactMap(\.request.id), [try XCTUnwrap(open.request.id)])
        XCTAssertNil(try f.reports.get(try XCTUnwrap(closed.report.id)))
        XCTAssertNil(try f.reports.get(try XCTUnwrap(reply.report.id)))
        XCTAssertNotNil(try f.reports.get(try XCTUnwrap(open.report.id)))
    }
}
