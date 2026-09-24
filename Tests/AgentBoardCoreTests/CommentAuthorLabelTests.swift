import Foundation
import XCTest
@testable import AgentBoardCore

/// Authors are written with the snapshots `WorkerToolHandler`, `ReviewerToolHandler` and
/// `OrchestratorToolHandler` actually produce; `TaskCommentToolTests` checks the same labels end to end.
final class CommentAuthorLabelTests: XCTestCase {
    func testEachAuthorIsNamedInWordsAndADeletedRosterAgentKeepsItsSnapshot() throws {
        let f = try Fixture.make()
        let task = try f.task("t", column: .review)
        let roster = RosterStore(f.db)
        let rita = try roster.create(name: "Rita", role: "reviewer", systemPrompt: "Review.")
        let otto = try roster.create(name: "Otto", role: "builder", systemPrompt: "Build.")
        let bee = try roster.create(name: "Worker Bee", role: "builder", systemPrompt: "Build.")

        var reviewer = f.session(taskId: task.id, shortId: "aa11bb")
        reviewer.rosterAgentId = rita.id
        var rosteredWorker = f.session(state: .completed, taskId: task.id, shortId: "cc33dd")
        rosteredWorker.rosterAgentId = rita.id
        let plainWorker = f.session(state: .completed, taskId: task.id, shortId: "3fa9c1")
        let plainReviewer = f.session(state: .completed, taskId: task.id, shortId: "77aa88")
        var deletedWorker = f.session(state: .completed, taskId: task.id, shortId: "ee55ff")
        deletedWorker.rosterAgentId = otto.id
        var deletedBee = f.session(state: .completed, taskId: task.id, shortId: "99bb00")
        deletedBee.rosterAgentId = bee.id
        for session in [reviewer, rosteredWorker, plainWorker, plainReviewer, deletedWorker, deletedBee] {
            try f.sessions.insert(session)
        }

        func add(_ author: CommentAuthor) throws {
            try f.board.addComment(projectId: f.project.id, taskId: task.id, author: author, body: "x")
        }
        try add(.human)
        try add(CommentAuthor(kind: .orchestrator, sessionId: "orch-1", name: "Orchestrator"))
        try add(CommentAuthor(kind: .reviewer, sessionId: reviewer.sessionId, rosterAgentId: rita.id, name: "Rita"))
        try add(CommentAuthor(kind: .worker, sessionId: rosteredWorker.sessionId, rosterAgentId: rita.id, name: "Rita"))
        try add(CommentAuthor(kind: .worker, sessionId: plainWorker.sessionId, name: "Worker 3fa9c1"))
        try add(CommentAuthor(kind: .reviewer, sessionId: plainReviewer.sessionId, name: plainReviewer.sessionId))
        try add(CommentAuthor(kind: .worker, sessionId: deletedWorker.sessionId, rosterAgentId: otto.id, name: "Otto"))
        try add(CommentAuthor(kind: .worker, sessionId: deletedBee.sessionId, rosterAgentId: bee.id, name: "Worker Bee"))

        try roster.delete(otto.id)
        try roster.delete(bee.id)
        var renamed = rita
        renamed.name = "Rita B"
        try roster.update(renamed)

        let thread = try CommentStore(f.db).thread(taskId: task.id)
        XCTAssertEqual(thread.comments.map { thread.authorLabel($0) }, [
            "You",
            "Orchestrator",
            "Rita B · reviewer",
            "Rita B · worker",
            "Worker 3fa9c1",
            "Reviewer 77aa88",
            "Otto · worker",
            "Worker Bee · worker",
        ])
        XCTAssertEqual(thread.comments.suffix(2).map(\.authorRosterAgentId), [nil, nil],
                       "the delete must have nulled the references")
    }

    func testAnUnrosteredAgentWithNoShortIdFallsBackToItsSessionIdPrefix() {
        let worker = TaskComment(
            taskId: "t", projectId: "p",
            author: CommentAuthor(kind: .worker, sessionId: "0123456789abcdef", name: "Worker 01234567"),
            body: "x", createdAt: 0
        )
        let reviewer = TaskComment(
            taskId: "t", projectId: "p",
            author: CommentAuthor(kind: .reviewer, sessionId: "fedcba9876543210", name: "fedcba9876543210"),
            body: "x", createdAt: 0
        )
        let unnamed = TaskComment(
            taskId: "t", projectId: "p",
            author: CommentAuthor(kind: .reviewer, name: "an unnamed reviewer"),
            body: "x", createdAt: 0
        )
        let thread = CommentThread(comments: [worker, reviewer, unnamed])
        XCTAssertEqual(thread.comments.map { thread.authorLabel($0) }, ["Worker 01234567", "Reviewer fedcba98", "Reviewer"])
    }
}
