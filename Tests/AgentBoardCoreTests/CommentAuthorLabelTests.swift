import Foundation
import XCTest
@testable import AgentBoardCore

final class CommentAuthorLabelTests: XCTestCase {
    func testEachAuthorIsNamedInWordsAndADeletedRosterAgentKeepsItsSnapshot() throws {
        let f = try Fixture.make()
        let task = try f.task("t", column: .review)
        let roster = RosterStore(f.db)
        let rita = try roster.create(name: "Rita", role: "reviewer", systemPrompt: "Review.")
        let otto = try roster.create(name: "Otto", role: "builder", systemPrompt: "Build.")

        var reviewer = f.session(taskId: task.id, shortId: "aa11bb22")
        reviewer.rosterAgentId = rita.id
        var rosteredWorker = f.session(state: .completed, taskId: task.id, shortId: "cc33dd44")
        rosteredWorker.rosterAgentId = rita.id
        let plainWorker = f.session(state: .completed, taskId: task.id, shortId: "3fa9c1e0")
        var deletedWorker = f.session(state: .completed, taskId: task.id, shortId: "ee55ff66")
        deletedWorker.rosterAgentId = otto.id
        for session in [reviewer, rosteredWorker, plainWorker, deletedWorker] { try f.sessions.insert(session) }

        func add(_ author: CommentAuthor) throws {
            try f.board.addComment(projectId: f.project.id, taskId: task.id, author: author, body: "x")
        }
        try add(.human)
        try add(CommentAuthor(kind: .orchestrator, sessionId: "orch-1", name: "Orchestrator"))
        try add(CommentAuthor(kind: .reviewer, sessionId: reviewer.sessionId, rosterAgentId: rita.id, name: "Rita"))
        try add(CommentAuthor(kind: .worker, sessionId: rosteredWorker.sessionId, rosterAgentId: rita.id, name: "Rita"))
        try add(CommentAuthor(kind: .worker, sessionId: plainWorker.sessionId, name: "Worker"))
        try add(CommentAuthor(kind: .worker, sessionId: deletedWorker.sessionId, rosterAgentId: otto.id, name: "Otto"))

        try roster.delete(otto.id)
        var renamed = rita
        renamed.name = "Rita B"
        try roster.update(renamed)

        let thread = try f.db.reader.read { try CommentStore.thread($0, taskId: task.id) }
        XCTAssertEqual(thread.comments.map { thread.authorLabel($0) }, [
            "You",
            "Orchestrator",
            "Rita B · reviewer",
            "Rita B · worker",
            "Worker 3fa9c1e0",
            "Otto · worker",
        ])
        XCTAssertNil(thread.comments.last?.authorRosterAgentId, "the delete must have nulled the reference")
    }

    func testAnUnrosteredAgentWithNoShortIdFallsBackToItsSessionIdPrefix() {
        let comment = TaskComment(
            taskId: "t", projectId: "p",
            author: CommentAuthor(kind: .reviewer, sessionId: "0123456789abcdef", name: "reviewer"),
            body: "x", createdAt: 0
        )
        XCTAssertEqual(CommentThread(comments: [comment]).authorLabel(comment), "Reviewer 01234567")
    }
}
