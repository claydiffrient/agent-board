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
        XCTAssertEqual(inserted.state, .setup)
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

final class BoardEpicTests: XCTestCase {
    private func plannedEpic(_ f: Fixture) throws -> (Epic, [BoardTask]) {
        try f.board.createEpic(
            projectId: f.project.id,
            title: "Search",
            goal: "make search fast",
            tasks: [
                NewEpicTask(title: "index", body: "build the index", acceptance: "index exists", priority: "p1", model: "opus"),
                NewEpicTask(title: "query", dependsOn: [0]),
                NewEpicTask(title: "ui", dependsOn: [1]),
            ]
        )
    }

    func testCreateEpicWritesTasksAndDepsAndRunsReadiness() throws {
        let f = try Fixture.make()
        let (epic, tasks) = try plannedEpic(f)

        XCTAssertEqual(epic.state, .planning)
        XCTAssertEqual(epic.branch, "agentboard/epic-\(epic.id)")
        XCTAssertEqual(tasks.map(\.title), ["index", "query", "ui"])
        XCTAssertEqual(tasks.map(\.epicId), [epic.id, epic.id, epic.id])
        XCTAssertEqual(tasks[0].body, "build the index")
        XCTAssertEqual(tasks[0].acceptance, "index exists")
        XCTAssertEqual(tasks[0].priority, "p1")
        XCTAssertEqual(tasks[0].model, "opus")
        XCTAssertEqual(tasks[0].origin, .orchestrator)

        XCTAssertEqual(try f.tasks.deps(of: tasks[1].id), [tasks[0].id])
        XCTAssertEqual(try f.tasks.deps(of: tasks[2].id), [tasks[1].id])
        XCTAssertEqual(try f.tasks.deps(of: tasks[0].id), [])

        XCTAssertEqual(tasks.map(\.column), [.ready, .backlog, .backlog])
        XCTAssertEqual(Set(try f.tasks.list(projectId: f.project.id, epicId: epic.id).map(\.id)), Set(tasks.map(\.id)))
    }

    func testCreateEpicRollsBackEverythingWhenADependencyIndexIsBad() throws {
        let f = try Fixture.make()
        XCTAssertThrowsError(
            try f.board.createEpic(
                projectId: f.project.id, title: "Doomed", goal: nil,
                tasks: [NewEpicTask(title: "a"), NewEpicTask(title: "b", dependsOn: [7])]
            )
        ) { error in
            XCTAssertEqual(error as? BoardError, .invalidEpicDependency(taskIndex: 1, dependsOn: 7))
        }

        XCTAssertEqual(try f.epics.list(projectId: f.project.id), [])
        XCTAssertEqual(try f.tasks.list(projectId: f.project.id), [])
    }

    func testCreateEpicRejectsSelfDependency() throws {
        let f = try Fixture.make()
        XCTAssertThrowsError(
            try f.board.createEpic(
                projectId: f.project.id, title: "Doomed", goal: nil,
                tasks: [NewEpicTask(title: "a", dependsOn: [0])]
            )
        ) { error in
            XCTAssertEqual(error as? BoardError, .invalidEpicDependency(taskIndex: 0, dependsOn: 0))
        }
        XCTAssertEqual(try f.epics.list(projectId: f.project.id), [])
        XCTAssertEqual(try f.tasks.list(projectId: f.project.id), [])
    }

    func testEpicReadyForIntegrationOnlyWhenEveryTaskIsDone() throws {
        let f = try Fixture.make()
        let (epic, tasks) = try plannedEpic(f)
        XCTAssertFalse(try f.board.epicReadyForIntegration(epicId: epic.id))

        for task in tasks {
            try f.tasks.move(task.id, to: .done)
            try f.tasks.refreshReadiness(projectId: f.project.id)
        }
        XCTAssertTrue(try f.board.epicReadyForIntegration(epicId: epic.id))

        try f.tasks.move(tasks[2].id, to: .review)
        XCTAssertFalse(try f.board.epicReadyForIntegration(epicId: epic.id))
    }

    func testEmptyEpicIsNotReadyForIntegrationAndUnknownEpicThrows() throws {
        let f = try Fixture.make()
        let epic = try f.epics.create(projectId: f.project.id, title: "empty", goal: nil)
        XCTAssertFalse(try f.board.epicReadyForIntegration(epicId: epic.id))

        XCTAssertThrowsError(try f.board.epicReadyForIntegration(epicId: "missing")) { error in
            XCTAssertEqual(error as? BoardError, .epicNotFound("missing"))
        }
    }

    func testAcceptingAnEpicTaskMovesTheEpicFromPlanningToActive() throws {
        let f = try Fixture.make()
        let (epic, tasks) = try plannedEpic(f)

        try f.board.assign(taskId: tasks[0].id, session: f.session("s1"))
        try f.board.complete(taskId: tasks[0].id, sessionId: "s1", summary: "indexed")
        XCTAssertEqual(try f.epics.get(epic.id)?.state, .planning)

        let ready = try f.board.accept(taskId: tasks[0].id)
        XCTAssertEqual(ready, [tasks[1].id])
        XCTAssertEqual(try f.epics.get(epic.id)?.state, .active)
    }

    func testAcceptNeverPromotesAnEpicPastActive() throws {
        let f = try Fixture.make()
        let (epic, tasks) = try plannedEpic(f)
        try f.epics.setState(epic.id, .integrating)

        try f.tasks.move(tasks[0].id, to: .review)
        try f.board.accept(taskId: tasks[0].id)
        XCTAssertEqual(try f.epics.get(epic.id)?.state, .integrating)

        try f.tasks.move(tasks[1].id, to: .review)
        try f.board.accept(taskId: tasks[1].id)
        try f.tasks.move(tasks[2].id, to: .review)
        try f.board.accept(taskId: tasks[2].id)
        XCTAssertEqual(try f.epics.get(epic.id)?.state, .integrating)
        XCTAssertTrue(try f.board.epicReadyForIntegration(epicId: epic.id))
    }

    func testAcceptingATaskWithNoEpicTouchesNoEpicState() throws {
        let f = try Fixture.make()
        let epic = try f.epics.create(projectId: f.project.id, title: "untouched", goal: nil)
        let loose = try f.task("loose", column: .review)

        try f.board.accept(taskId: loose.id)
        XCTAssertEqual(try f.epics.get(epic.id)?.state, .planning)
    }
}
