import XCTest
@testable import AgentBoardCore

/// SPEC §13.8: releasing an issue takeover closes its task when the task has not started.
final class TakeoverReleaseTests: XCTestCase {
    func testAReleasedTakeoverClosesItsUnstartedTask() throws {
        let f = try Fixture.make()
        let store = TakeoverStore(f.db)
        let row = try XCTUnwrap(try store.record(projectId: f.project.id, TakeoverCandidate(
            githubNodeId: "I_issue12", kind: .issue, number: 12,
            url: "https://github.com/example-org/app/issues/12", title: "Crash on launch", author: "example-colleague"
        )))
        let issue = TakeoverIssue(
            number: 12, title: "Crash on launch", url: row.url, author: "example-colleague", body: "It crashes."
        )
        let task = try XCTUnwrap(try store.createTask(row.id, issue: issue))
        try store.acknowledge(row.id)
        try store.startWorking(row.id, taskId: task.id)
        XCTAssertEqual(try f.tasks.get(task.id)?.column, .ready)

        try store.release(row.id)

        let closed = try XCTUnwrap(try f.tasks.get(task.id))
        XCTAssertEqual(closed.column, .closed)
        XCTAssertTrue(closed.closedReason?.contains("released from takeover") == true)
        XCTAssertEqual(try store.get(row.id)?.state, .released)
    }

    func testFailureTextClearsWhenTheRowMovesOn() throws {
        let f = try Fixture.make()
        let store = TakeoverStore(f.db)
        let row = try XCTUnwrap(try store.record(projectId: f.project.id, TakeoverCandidate(
            githubNodeId: "I_issue12", kind: .issue, number: 12,
            url: "https://github.com/example-org/app/issues/12", title: "Crash on launch", author: "example-colleague"
        )))
        let task = try XCTUnwrap(try store.createTask(row.id, issue: TakeoverIssue(
            number: 12, title: "Crash on launch", url: row.url, author: "example-colleague", body: "It crashes."
        )))

        try store.noteProblem(row.id, detail: "The label edit failed.")
        XCTAssertNil(try store.acknowledge(row.id)?.failure)
        try store.noteProblem(row.id, detail: "The acknowledgment comment did not post.")
        XCTAssertNil(try store.startWorking(row.id, taskId: task.id)?.failure)
        try store.noteProblem(row.id, detail: "A later step failed.")
        XCTAssertNil(try store.finish(row.id)?.failure)
    }

    func testReleasingAnAdoptedPullRequestMidRoundRefusesItsPush() throws {
        let f = try Fixture.make()
        let store = TakeoverStore(f.db)
        let row = try XCTUnwrap(try store.record(projectId: f.project.id, TakeoverCandidate(
            githubNodeId: "PR_12", kind: .pr, number: 12, url: "https://github.com/example-org/app/pull/12",
            title: "Add widgets", author: "example-colleague"
        )))
        let watch = try XCTUnwrap(PRWatchStore(f.db).adopt(row))
        try store.acknowledge(row.id)
        try store.watch(row.id, watchId: watch.id)
        try f.db.writer.write { try $0.execute(sql: "UPDATE pr_watch SET state = 'fixing', round = 1") }
        XCTAssertEqual(try PRWatchStore(f.db).get(watch.id)?.acceptsFastForward, true)

        try store.release(row.id)

        let released = try XCTUnwrap(PRWatchStore(f.db).get(watch.id))
        XCTAssertEqual(released.state, .fixing)
        XCTAssertFalse(released.acceptsFastForward, "publishing must park this round instead of pushing")
    }
}
