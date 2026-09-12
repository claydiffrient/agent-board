import Foundation
import XCTest
@testable import AgentBoardCore

final class BoardTests: XCTestCase {
    func testAssignCompleteAcceptPath() throws {
        let f = try Fixture.make()
        let t = try f.task("build it", column: .ready)
        let downstream = try f.task("after")
        try f.tasks.setDeps(downstream.id, dependsOn: [t.id])
        try f.tasks.refreshReadiness(projectId: f.project.id)
        XCTAssertEqual(try f.tasks.get(downstream.id)?.column, .backlog)

        let inserted = try f.board.assign(taskId: t.id, session: f.session("s1", state: .running))
        XCTAssertEqual(inserted.taskId, t.id)
        XCTAssertEqual(inserted.role, .worker)
        XCTAssertEqual(inserted.state, .starting)
        XCTAssertEqual(inserted.attempt, 1)
        XCTAssertEqual(try f.tasks.get(t.id)?.column, .running)
        XCTAssertEqual(try f.sessions.get("s1"), inserted)

        let report = try f.board.complete(taskId: t.id, sessionId: "s1", summary: "shipped")
        XCTAssertEqual(report.kind, .complete)
        XCTAssertEqual(report.body, "shipped")
        XCTAssertNotNil(report.id)
        XCTAssertEqual(try f.tasks.get(t.id)?.column, .review)
        let session = try XCTUnwrap(f.sessions.get("s1"))
        XCTAssertEqual(session.state, .completed)
        XCTAssertNotNil(session.endedAt)
        XCTAssertEqual(try f.reports.unconsumed(projectId: f.project.id).map(\.id), [report.id])

        let nowReady = try f.board.accept(taskId: t.id)
        XCTAssertEqual(nowReady, [downstream.id])
        XCTAssertEqual(try f.tasks.get(t.id)?.column, .done)
        XCTAssertEqual(try f.tasks.get(downstream.id)?.column, .ready)
    }

    func testAttemptCounterIncrementsPerTask() throws {
        let f = try Fixture.make()
        let t = try f.task("retry me", column: .ready)
        let other = try f.task("other", column: .ready)

        let first = try f.board.assign(taskId: t.id, session: f.session("s1"))
        try f.board.fail(taskId: t.id, sessionId: "s1", reason: "boom")
        try f.board.reopen(taskId: t.id)
        let second = try f.board.assign(taskId: t.id, session: f.session("s2"))
        let unrelated = try f.board.assign(taskId: other.id, session: f.session("s3"))

        XCTAssertEqual(first.attempt, 1)
        XCTAssertEqual(second.attempt, 2)
        XCTAssertEqual(unrelated.attempt, 1)
        XCTAssertEqual(try f.sessions.forTask(t.id).map(\.sessionId), ["s2", "s1"])
    }

    func testFailSetsFlagAndReportAndClearsOnReopen() throws {
        let f = try Fixture.make()
        let t = try f.task("t", column: .ready)
        try f.board.assign(taskId: t.id, session: f.session("s1"))
        let report = try f.board.fail(taskId: t.id, sessionId: "s1", reason: "tests red")

        let failed = try XCTUnwrap(f.tasks.get(t.id))
        XCTAssertTrue(failed.failed)
        XCTAssertEqual(failed.failureReason, "tests red")
        XCTAssertEqual(failed.column, .running)
        XCTAssertEqual(report.kind, .failed)
        XCTAssertEqual(try f.sessions.get("s1")?.state, .failed)
        XCTAssertNotNil(try f.sessions.get("s1")?.endedAt)

        try f.board.reopen(taskId: t.id)
        let reopened = try XCTUnwrap(f.tasks.get(t.id))
        XCTAssertEqual(reopened.column, .ready)
        XCTAssertFalse(reopened.failed)
        XCTAssertNil(reopened.failureReason)
    }

    func testBlockAndUnblock() throws {
        let f = try Fixture.make()
        let t = try f.task("t", column: .ready)
        try f.board.assign(taskId: t.id, session: f.session("s1"))
        try f.sessions.setState("s1", .running)

        let report = try f.board.block(taskId: t.id, sessionId: "s1", reason: "needs permission")
        XCTAssertEqual(report.kind, .blocked)
        let blocked = try XCTUnwrap(f.tasks.get(t.id))
        XCTAssertTrue(blocked.blocked)
        XCTAssertEqual(blocked.blockedReason, "needs permission")
        XCTAssertEqual(blocked.column, .running)
        XCTAssertEqual(try f.sessions.get("s1")?.state, .blocked)

        try f.board.unblock(taskId: t.id, sessionId: "s1")
        XCTAssertFalse(try XCTUnwrap(f.tasks.get(t.id)).blocked)
        XCTAssertEqual(try f.sessions.get("s1")?.state, .running)
    }

    func testProposeAndPromote() throws {
        let f = try Fixture.make()
        let proposed = try f.board.propose(
            projectId: f.project.id, title: "Add lint", body: "Run eslint", rationale: "caught a bug", sessionId: nil
        )
        XCTAssertEqual(proposed.column, .proposed)
        XCTAssertEqual(proposed.origin, .workerProposal)
        let reports = try f.reports.unconsumed(projectId: f.project.id)
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0].kind, .proposal)
        XCTAssertEqual(reports[0].taskId, proposed.id)
        XCTAssertTrue(reports[0].body.contains("caught a bug"))

        let nowReady = try f.board.promote(taskId: proposed.id)
        XCTAssertEqual(nowReady, [proposed.id])
        XCTAssertEqual(try f.tasks.get(proposed.id)?.column, .ready)

        XCTAssertThrowsError(try f.board.promote(taskId: proposed.id)) { error in
            XCTAssertEqual(error as? BoardError, .invalidTransition(taskId: proposed.id, from: .ready, to: .backlog))
        }
    }

    func testPromoteWithUnmetDepsStaysInBacklog() throws {
        let f = try Fixture.make()
        let blocker = try f.task("blocker")
        let proposed = try f.board.propose(projectId: f.project.id, title: "later", body: nil, rationale: nil, sessionId: nil)
        try f.tasks.setDeps(proposed.id, dependsOn: [blocker.id])
        let nowReady = try f.board.promote(taskId: proposed.id)
        XCTAssertEqual(nowReady, [blocker.id])
        XCTAssertEqual(try f.tasks.get(proposed.id)?.column, .backlog)
    }

    func testAssignUnknownTaskThrows() throws {
        let f = try Fixture.make()
        XCTAssertThrowsError(try f.board.assign(taskId: "missing", session: f.session())) { error in
            XCTAssertEqual(error as? BoardError, .taskNotFound("missing"))
        }
        XCTAssertEqual(try f.sessions.all(projectId: f.project.id).count, 0)
    }
}
