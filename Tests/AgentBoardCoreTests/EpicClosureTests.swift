import XCTest
@testable import AgentBoardCore

final class EpicClosureTests: XCTestCase {
    private func epic(_ f: Fixture, tasks specs: [NewEpicTask] = []) throws -> Epic {
        try f.board.createEpic(projectId: f.project.id, title: "Ship it", goal: nil, tasks: specs).0
    }

    // MARK: The state is written and nothing else moves

    func testCloseAsDoneWritesDoneAndLeavesEveryTaskWhereItIs() throws {
        let f = try Fixture.make()
        let (epic, created) = try f.board.createEpic(
            projectId: f.project.id, title: "Ship it", goal: nil,
            tasks: [NewEpicTask(title: "One"), NewEpicTask(title: "Two"), NewEpicTask(title: "Three")]
        )
        try f.tasks.move(created[0].id, to: .done)
        try f.tasks.move(created[2].id, to: .review)
        let before = try f.tasks.list(projectId: f.project.id, column: nil, epicId: epic.id)

        try f.board.closeEpic(epicId: epic.id, as: .done, by: .human)

        XCTAssertEqual(try EpicStore(f.db).get(epic.id)?.state, .done)
        let after = try f.tasks.list(projectId: f.project.id, column: nil, epicId: epic.id)
        XCTAssertEqual(after.map(\.id), before.map(\.id), "closing moved a task out of the epic")
        XCTAssertEqual(after.map(\.column), before.map(\.column), "closing moved a task between columns")
        XCTAssertTrue(after.allSatisfy { $0.epicId == epic.id }, "closing cleared epic_id on a task")
        XCTAssertTrue(after.allSatisfy { !$0.isArchived }, "closing archived a task")
    }

    func testAbandonWritesAbandoned() throws {
        let f = try Fixture.make()
        let e = try epic(f, tasks: [NewEpicTask(title: "One")])
        try f.board.closeEpic(epicId: e.id, as: .abandoned, by: .human)
        XCTAssertEqual(try EpicStore(f.db).get(e.id)?.state, .abandoned)
    }

    /// The epic branch is never rewritten by closing: the row keeps the name it was cut with, and
    /// the task branches are derived from task ids, which closing does not delete.
    func testClosingKeepsTheEpicBranchAndEveryTaskId() throws {
        let f = try Fixture.make()
        let (e, created) = try f.board.createEpic(
            projectId: f.project.id, title: "Ship it", goal: nil,
            tasks: [NewEpicTask(title: "One"), NewEpicTask(title: "Two")]
        )
        let branch = e.branch
        let taskBranches = created.map { TaskStore.branchName(for: $0.id) }

        try f.board.closeEpic(epicId: e.id, as: .abandoned, by: .human)

        XCTAssertEqual(try EpicStore(f.db).get(e.id)?.branch, branch)
        XCTAssertEqual(
            try f.tasks.list(projectId: f.project.id, column: nil, epicId: e.id)
                .map { TaskStore.branchName(for: $0.id) },
            taskBranches
        )
    }

    func testUnknownEpicThrows() throws {
        let f = try Fixture.make()
        XCTAssertThrowsError(try f.board.closeEpic(epicId: "nope", as: .done, by: .human)) { error in
            XCTAssertEqual(error as? BoardError, .epicNotFound("nope"))
        }
    }

    // MARK: A live worker refuses the close

    func testRefusedWhileASessionIsActiveInTheEpic() throws {
        let f = try Fixture.make()
        let (e, created) = try f.board.createEpic(
            projectId: f.project.id, title: "Ship it", goal: nil, tasks: [NewEpicTask(title: "One")]
        )
        try f.sessions.insert(f.session("s1", state: .running, taskId: created[0].id))

        XCTAssertThrowsError(try f.board.closeEpic(epicId: e.id, as: .done, by: .human)) { error in
            XCTAssertEqual(error as? BoardError, .epicHasRunningWorkers(epicId: e.id, sessionIds: ["s1"]))
        }
        XCTAssertEqual(try EpicStore(f.db).get(e.id)?.state, .planning, "a refused close still wrote the state")
    }

    /// `setup` and `blocked` are active too: a worker in either is a real process against the epic.
    func testEverySessionStateCountsAsRunningOrNot() throws {
        for state in SessionState.allCases {
            let f = try Fixture.make()
            let (e, created) = try f.board.createEpic(
                projectId: f.project.id, title: "Ship it", goal: nil, tasks: [NewEpicTask(title: "One")]
            )
            try f.sessions.insert(f.session("s1", state: state, taskId: created[0].id))
            let plan = try f.board.epicClosurePlan(epicId: e.id, as: .done)
            XCTAssertEqual(plan.running.isEmpty, !state.isActive, "\(state) was classified wrong")
        }
    }

    func testAnActiveSessionOnAnotherEpicDoesNotRefuse() throws {
        let f = try Fixture.make()
        let mine = try epic(f, tasks: [NewEpicTask(title: "One")])
        let (theirs, theirTasks) = try f.board.createEpic(
            projectId: f.project.id, title: "Elsewhere", goal: nil, tasks: [NewEpicTask(title: "Other")]
        )
        try f.sessions.insert(f.session("s1", state: .running, taskId: theirTasks[0].id))

        try f.board.closeEpic(epicId: mine.id, as: .done, by: .human)
        XCTAssertEqual(try EpicStore(f.db).get(mine.id)?.state, .done)
        XCTAssertEqual(try EpicStore(f.db).get(theirs.id)?.state, .planning)
    }

    /// The integrator is bound to a synthetic task inside the epic, so abandoning an epic that is
    /// mid-integration must refuse rather than orphan the integrator.
    func testRefusedWhileTheIntegratorIsRunning() throws {
        let f = try Fixture.make()
        let e = try epic(f, tasks: [NewEpicTask(title: "One")])
        let integrator = try f.board.createIntegrationTask(epicId: e.id)
        try EpicStore(f.db).setState(e.id, .integrating)
        try f.sessions.insert(f.session("integ", state: .starting, taskId: integrator.id))

        XCTAssertThrowsError(try f.board.closeEpic(epicId: e.id, as: .abandoned, by: .human))
        XCTAssertEqual(try EpicStore(f.db).get(e.id)?.state, .integrating)
    }

    func testAnEndedSessionDoesNotRefuse() throws {
        let f = try Fixture.make()
        let (e, created) = try f.board.createEpic(
            projectId: f.project.id, title: "Ship it", goal: nil, tasks: [NewEpicTask(title: "One")]
        )
        try f.sessions.insert(f.session("s1", state: .completed, taskId: created[0].id))
        try f.board.closeEpic(epicId: e.id, as: .done, by: .human)
        XCTAssertEqual(try EpicStore(f.db).get(e.id)?.state, .done)
    }

    // MARK: Terminal is terminal

    func testAClosedEpicCannotBeClosedAgainIntoTheOtherTerminalState() throws {
        let f = try Fixture.make()
        let e = try epic(f)
        try f.board.closeEpic(epicId: e.id, as: .done, by: .human)

        XCTAssertThrowsError(try f.board.closeEpic(epicId: e.id, as: .abandoned, by: .human)) { error in
            XCTAssertEqual(error as? BoardError, .epicAlreadyClosed(epicId: e.id, state: .done))
        }
        XCTAssertEqual(try EpicStore(f.db).get(e.id)?.state, .done)
    }

    func testAnAbandonedEpicCannotBeClosedAsDone() throws {
        let f = try Fixture.make()
        let e = try epic(f)
        try f.board.closeEpic(epicId: e.id, as: .abandoned, by: .human)
        XCTAssertThrowsError(try f.board.closeEpic(epicId: e.id, as: .done, by: .human))
        XCTAssertEqual(try EpicStore(f.db).get(e.id)?.state, .abandoned)
    }

    func testClosingIntoTheSameStateTwiceIsAlsoRefused() throws {
        let f = try Fixture.make()
        let e = try epic(f)
        try f.board.closeEpic(epicId: e.id, as: .done, by: .human)
        XCTAssertThrowsError(try f.board.closeEpic(epicId: e.id, as: .done, by: .human))
        XCTAssertEqual(try f.reports.unconsumed(projectId: f.project.id).count, 1, "the refused close queued a second report")
    }

    func testAnEpicIntegratedTheNormalWayIsStillRefusedAfterwards() throws {
        let f = try Fixture.make()
        let e = try epic(f)
        try EpicStore(f.db).setState(e.id, .done)
        XCTAssertThrowsError(try f.board.closeEpic(epicId: e.id, as: .abandoned, by: .human))
    }

    // MARK: The decision report

    func testQueuesADecisionReportNamingTheStateAndTheLeftovers() throws {
        let f = try Fixture.make()
        let (e, created) = try f.board.createEpic(
            projectId: f.project.id, title: "Ship it", goal: nil,
            tasks: [NewEpicTask(title: "Done one"), NewEpicTask(title: "Half done")]
        )
        try f.tasks.move(created[0].id, to: .done)

        let report = try f.board.closeEpic(epicId: e.id, as: .abandoned, by: .human)

        XCTAssertEqual(report.kind, .decision)
        XCTAssertEqual(report.projectId, f.project.id)
        XCTAssertTrue(report.body.contains("abandoned"), report.body)
        XCTAssertTrue(report.body.contains("Do not plan or dispatch further work into it"), report.body)
        XCTAssertTrue(report.body.contains(e.branch), report.body)
        XCTAssertTrue(report.body.contains(created[1].id), report.body)
        XCTAssertFalse(report.body.contains(created[0].id), "a finished task was listed as unfinished")
        XCTAssertTrue(report.body.contains("set_epic(task_id)"), report.body)
    }

    func testReportSaysSoWhenNothingWasLeftOver() throws {
        let f = try Fixture.make()
        let (e, created) = try f.board.createEpic(
            projectId: f.project.id, title: "Ship it", goal: nil, tasks: [NewEpicTask(title: "One")]
        )
        try f.tasks.move(created[0].id, to: .done)
        let report = try f.board.closeEpic(epicId: e.id, as: .done, by: .human)
        XCTAssertTrue(report.body.contains("Every task in the epic was already finished."), report.body)
    }

    // MARK: The plan the confirmation reads

    func testPlanListsUnfinishedTasksInBoardOrder() throws {
        let f = try Fixture.make()
        let (e, created) = try f.board.createEpic(
            projectId: f.project.id, title: "Ship it", goal: nil,
            tasks: [NewEpicTask(title: "Alpha"), NewEpicTask(title: "Beta"), NewEpicTask(title: "Gamma")]
        )
        try f.tasks.move(created[1].id, to: .done)

        let plan = try f.board.epicClosurePlan(epicId: e.id, as: .done)
        XCTAssertEqual(plan.unfinished.map(\.id), [created[0].id, created[2].id])
        XCTAssertEqual(plan.unfinished.map(\.title), ["Alpha", "Gamma"])
        XCTAssertFalse(plan.isRefused)
        XCTAssertEqual(plan.branch, e.branch)
    }

    /// Everything the acceptance criteria require the human to read before committing.
    func testTheConfirmationSaysWhatIsAndIsNotTouched() throws {
        let f = try Fixture.make()
        let (e, created) = try f.board.createEpic(
            projectId: f.project.id, title: "Ship it", goal: nil,
            tasks: [NewEpicTask(title: "Alpha"), NewEpicTask(title: "Beta")]
        )
        try f.tasks.move(created[0].id, to: .review)

        let message = try f.board.epicClosurePlan(epicId: e.id, as: .done).message
        XCTAssertTrue(message.contains("does not merge \(e.branch)"), message)
        XCTAssertTrue(message.contains("does not open a pull request"), message)
        XCTAssertTrue(message.contains("touch any task branch"), message)
        XCTAssertTrue(message.contains("stay exactly where they are"), message)
        XCTAssertTrue(message.contains("Alpha (review)"), message)
        XCTAssertTrue(message.contains("Beta (ready)"), message)
        XCTAssertTrue(message.contains("Every branch and worktree survives"), message)
    }

    func testTheConfirmationNamesTheRunningWorkersInsteadOfPromisingAClose() throws {
        let f = try Fixture.make()
        let (e, created) = try f.board.createEpic(
            projectId: f.project.id, title: "Ship it", goal: nil, tasks: [NewEpicTask(title: "Alpha")]
        )
        var session = f.session("s1", state: .running, taskId: created[0].id)
        session.shortId = "ab12cd34"
        try f.sessions.insert(session)

        let plan = try f.board.epicClosurePlan(epicId: e.id, as: .abandoned)
        XCTAssertTrue(plan.isRefused)
        XCTAssertEqual(plan.running.map(\.taskTitle), ["Alpha"])
        XCTAssertTrue(plan.message.contains("still running in this epic"), plan.message)
        XCTAssertTrue(plan.message.contains("ab12cd34"), plan.message)
        XCTAssertFalse(plan.message.contains("Every branch and worktree survives"), plan.message)
    }

    func testAClosedEpicsPlanSaysItIsAlreadyClosed() throws {
        let f = try Fixture.make()
        let e = try epic(f)
        try f.board.closeEpic(epicId: e.id, as: .done, by: .human)
        let plan = try f.board.epicClosurePlan(epicId: e.id, as: .abandoned)
        XCTAssertEqual(plan.alreadyClosed, .done)
        XCTAssertTrue(plan.isRefused)
        XCTAssertTrue(plan.message.contains("already done, and closing is one way"), plan.message)
    }

    func testPlanTitleNamesTheEpicAndTheChoice() throws {
        let f = try Fixture.make()
        let e = try epic(f)
        XCTAssertEqual(try f.board.epicClosurePlan(epicId: e.id, as: .done).title, "Close \"Ship it\" as done?")
        XCTAssertEqual(try f.board.epicClosurePlan(epicId: e.id, as: .abandoned).title, "Abandon \"Ship it\"?")
    }

    // MARK: Lane actions

    func testAnUnfinishedEpicOffersBothWaysToEndIt() {
        XCTAssertEqual(
            EpicLane.actions(state: .active, readyForIntegration: false), [.closeAsDone, .abandon]
        )
        XCTAssertEqual(
            EpicLane.actions(state: .active, readyForIntegration: true),
            [.requestIntegration, .closeAsDone, .abandon]
        )
        XCTAssertEqual(EpicLane.actions(state: .integrating, readyForIntegration: true), [.closeAsDone, .abandon])
    }

    func testAClosedEpicOffersNoWayToCloseItAgain() {
        for state: EpicState in [.done, .abandoned] {
            let closures = EpicLane.actions(state: state, readyForIntegration: true).compactMap(\.closure)
            XCTAssertTrue(closures.isEmpty, "\(state) still offered \(closures)")
        }
    }

    func testEveryLaneActionMapsToTheStateItWrites() {
        XCTAssertEqual(EpicLaneAction.closeAsDone.closure?.state, .done)
        XCTAssertEqual(EpicLaneAction.abandon.closure?.state, .abandoned)
        XCTAssertNil(EpicLaneAction.requestIntegration.closure)
        XCTAssertNil(EpicLaneAction.openPullRequest.closure)
    }
}
