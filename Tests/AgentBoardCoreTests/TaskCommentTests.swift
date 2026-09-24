import Foundation
import GRDB
import XCTest
@testable import AgentBoardCore

extension Fixture {
    var comments: CommentStore { CommentStore(db) }
}

final class TaskCommentTests: XCTestCase {
    func testThreadKeepsAuthorsThroughRosterDeleteAndGoesWithItsTask() throws {
        let f = try Fixture.make()
        let task = try f.task("t", column: .review)
        let other = try f.task("other")
        let rita = try RosterStore(f.db).create(name: "Rita", role: "reviewer", systemPrompt: "Review.")

        let worker = f.session(taskId: task.id)
        var reviewer = f.session(state: .completed, taskId: task.id)
        reviewer.rosterAgentId = rita.id
        try f.sessions.insert(worker)
        try f.sessions.insert(reviewer)

        let human = try f.board.addComment(projectId: f.project.id, taskId: task.id, author: .human, body: "  Check the edge case.\n")
        try f.board.addComment(
            projectId: f.project.id, taskId: task.id,
            author: CommentAuthor(kind: .orchestrator, sessionId: "orch-1", name: "Orchestrator"), body: "Scoped to Core."
        )
        try f.board.addComment(
            projectId: f.project.id, taskId: task.id,
            author: CommentAuthor(kind: .worker, sessionId: worker.sessionId, name: "Worker"), body: "Done; see tests."
        )
        try f.board.addComment(
            projectId: f.project.id, taskId: task.id,
            author: CommentAuthor(kind: .reviewer, sessionId: reviewer.sessionId, rosterAgentId: rita.id, name: rita.name),
            body: "Looks right."
        )
        try f.comments.add(taskId: other.id, author: .human, body: "Unrelated.")

        XCTAssertEqual(human.body, "Check the edge case.")
        XCTAssertEqual(human.authorName, "human")
        XCTAssertEqual(human.projectId, f.project.id)

        let thread = try f.comments.list(taskId: task.id)
        XCTAssertEqual(thread.map(\.authorKind), [.human, .orchestrator, .worker, .reviewer])
        XCTAssertEqual(thread.map(\.authorName), ["human", "Orchestrator", "Worker", "Rita"])
        XCTAssertEqual(thread.map(\.authorSessionId), [nil, "orch-1", worker.sessionId, reviewer.sessionId])
        XCTAssertEqual(thread.map(\.authorRosterAgentId), [nil, nil, nil, rita.id])

        try f.db.writer.write { db in
            try db.execute(sql: "UPDATE task_comment SET created_at = created_at + 1000 WHERE id = ?", arguments: [human.id])
        }
        XCTAssertEqual(try f.comments.list(taskId: task.id).last?.id, human.id, "ordered by created_at, not insertion")
        XCTAssertEqual(try f.comments.counts(projectId: f.project.id), [task.id: 4, other.id: 1])

        try RosterStore(f.db).delete(rita.id)
        let ritas = try XCTUnwrap(try f.comments.list(taskId: task.id).first { $0.authorKind == .reviewer })
        XCTAssertEqual(ritas.authorName, "Rita")
        XCTAssertNil(ritas.authorRosterAgentId)
        XCTAssertEqual(ritas.authorSessionId, reviewer.sessionId)

        try f.db.writer.write { db in
            try db.execute(sql: "DELETE FROM agent_session WHERE task_id = ?", arguments: [task.id])
            try db.execute(sql: "UPDATE report SET task_id = NULL WHERE task_id = ?", arguments: [task.id])
            try db.execute(sql: "DELETE FROM task WHERE id = ?", arguments: [task.id])
        }
        XCTAssertEqual(try f.comments.list(taskId: task.id), [])
        XCTAssertEqual(try f.comments.counts(projectId: f.project.id), [other.id: 1])

        try f.projects.delete(f.project.id)
        let left = try f.db.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM task_comment") }
        XCTAssertEqual(left, 0)
    }

    func testAddCommentRefusesMissingAndForeignTasksAndBadBodies() throws {
        let f = try Fixture.make()
        let task = try f.task("t")
        let theirs = try f.tasks.create(
            projectId: try f.otherProject().id, title: "theirs", body: nil, acceptance: nil, priority: nil,
            column: .backlog, origin: .human, epicId: nil
        )

        XCTAssertThrowsError(try f.board.addComment(projectId: f.project.id, taskId: "missing", author: .human, body: "x")) {
            XCTAssertEqual($0 as? BoardError, .taskNotFound("missing"))
        }
        XCTAssertThrowsError(try f.board.addComment(projectId: f.project.id, taskId: theirs.id, author: .human, body: "x")) {
            XCTAssertEqual($0 as? BoardError, .taskNotFound(theirs.id))
        }
        XCTAssertThrowsError(try f.board.addComment(projectId: f.project.id, taskId: task.id, author: .human, body: " \n ")) {
            XCTAssertEqual($0 as? CommentError, .emptyBody)
        }
        let tooLong = String(repeating: "a", count: TaskComment.maxBodyLength + 1)
        XCTAssertThrowsError(try f.board.addComment(projectId: f.project.id, taskId: task.id, author: .human, body: tooLong)) {
            XCTAssertEqual($0 as? CommentError, .bodyTooLong(limit: TaskComment.maxBodyLength))
        }
        let atCap = String(repeating: "a", count: TaskComment.maxBodyLength)
        try f.board.addComment(projectId: f.project.id, taskId: task.id, author: .human, body: atCap)

        XCTAssertEqual(try f.comments.list(taskId: task.id).count, 1)
        XCTAssertEqual(try f.comments.list(taskId: theirs.id), [])
    }

    /// Each write is issued from inside the observation loop, so an emission is proof the
    /// observation produced it.
    func testObservationEmitsWhenItsTaskGainsAComment() async throws {
        let f = try Fixture.make()
        let task = try f.task("t")
        let other = try f.task("other")

        var stage = 0
        for try await thread in f.comments.observe(taskId: task.id).values(in: f.db.reader) {
            switch stage {
            case 0:
                XCTAssertEqual(thread, [])
                stage = 1
                try f.comments.add(taskId: other.id, author: .human, body: "elsewhere")
                try f.comments.add(taskId: task.id, author: .human, body: "first")
            default:
                guard !thread.isEmpty else { continue }
                XCTAssertEqual(thread.map(\.body), ["first"])
                return
            }
        }
    }
}
