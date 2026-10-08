import XCTest
@testable import AgentBoardCore

/// SPEC §5 `closed`: retired without being done.
final class TaskClosureTests: XCTestCase {
    private func refusal(_ f: Fixture, _ taskId: String, reason: String = "superseded") -> String? {
        do {
            try f.board.close(taskId: taskId, reason: reason, by: .orchestrator(sessionId: nil))
            return nil
        } catch BoardError.closeRefused(_, let message) {
            return message
        } catch {
            XCTFail("unexpected \(error)")
            return nil
        }
    }

    func testCloseIsRefusedForABlankReasonADoneTaskAnIntegrationTaskAndALiveSession() throws {
        let f = try Fixture.make()
        let ready = try f.task("ready", column: .ready)
        XCTAssertNotNil(refusal(f, ready.id, reason: "  \n"))

        let done = try f.task("accepted", column: .done)
        XCTAssertNotNil(refusal(f, done.id))

        let integration = try f.task("integrate", column: .ready, origin: .integration)
        XCTAssertNotNil(refusal(f, integration.id))

        let running = try f.task("running", column: .ready)
        _ = try f.board.assign(taskId: running.id, session: f.session(taskId: running.id))
        XCTAssertNotNil(refusal(f, running.id))

        for task in [ready, done, integration, running] {
            XCTAssertNotEqual(try f.tasks.get(task.id)?.column, .closed, task.title)
        }
    }

    func testADependentOfAClosedTaskStaysInBacklog() throws {
        let f = try Fixture.make()
        let dependency = try f.task("design the toggle", column: .ready)
        let dependent = try f.task("build the toggle")
        try f.tasks.setDeps(dependent.id, dependsOn: [dependency.id])
        try f.tasks.refreshReadiness(projectId: f.project.id)

        let closure = try f.board.close(
            taskId: dependency.id, reason: "Designed in the orchestrator session", by: .orchestrator(sessionId: nil)
        )
        try f.tasks.refreshReadiness(projectId: f.project.id)

        XCTAssertEqual(closure.waitingDependents.map(\.id), [dependent.id])
        XCTAssertEqual(try f.tasks.get(dependent.id)?.column, .backlog)
    }

    func testCloseThenReopenRestoresTheTaskAndKeepsTheReasonInItsHistory() throws {
        let f = try Fixture.make()
        let task = try f.task("obsolete", column: .ready)

        try f.board.close(taskId: task.id, reason: "Done in Paper", by: .orchestrator(sessionId: nil))
        let closed = try XCTUnwrap(f.tasks.get(task.id))
        XCTAssertEqual(closed.column, .closed)
        XCTAssertEqual(closed.closedReason, "Done in Paper")
        XCTAssertEqual(closed.closedBy, "the orchestrator")
        XCTAssertNotNil(closed.closedAt)
        XCTAssertNil(closed.landing)
        guard case .refused = try f.board.requestSpawn(taskId: task.id, requestedBy: "orch") else {
            return XCTFail("a closed task must not be spawnable")
        }

        let report = try f.board.reopen(taskId: task.id)
        let reopened = try XCTUnwrap(f.tasks.get(task.id))
        XCTAssertEqual(reopened.column, .ready)
        XCTAssertNil(reopened.closedReason)
        XCTAssertNil(reopened.closedAt)
        XCTAssertTrue(report.body.contains("Done in Paper"), report.body)
        XCTAssertTrue(try f.progress.list(taskId: task.id).contains { $0.text.contains("Done in Paper") })
    }

    func testAnEpicWhoseOtherTasksAreDoneIsReadyForIntegrationOnlyWithOneDone() throws {
        let f = try Fixture.make()
        let epic = try EpicStore(f.db).create(projectId: f.project.id, title: "Theme", goal: nil)
        func member(_ title: String, _ column: TaskColumn) throws -> BoardTask {
            try f.tasks.create(
                projectId: f.project.id, title: title, body: nil, acceptance: nil, priority: nil,
                column: column, origin: .orchestrator, epicId: epic.id
            )
        }
        let obsolete = try member("design", .ready)
        try f.board.close(taskId: obsolete.id, reason: "superseded", by: .orchestrator(sessionId: nil))
        XCTAssertFalse(try f.board.epicReadyForIntegration(epicId: epic.id))

        _ = try member("build", .done)
        XCTAssertTrue(try f.board.epicReadyForIntegration(epicId: epic.id))
    }
}
