import XCTest
@testable import AgentBoardCore

final class EpicLaneTests: XCTestCase {
    func testTaskCountTalliesOnlyDone() {
        let count = EpicLane.taskCount(columns: [.backlog, .done, .running, .done, .review])
        XCTAssertEqual(count.done, 2)
        XCTAssertEqual(count.total, 5)
        XCTAssertEqual(count.label, "2/5 done")
        XCTAssertFalse(count.readyForIntegration)
    }

    func testEmptyLaneCountsZeroAndIsNotReady() {
        let count = EpicLane.taskCount(columns: [])
        XCTAssertEqual(count.label, "0/0 done")
        XCTAssertFalse(count.readyForIntegration)
    }

    func testAllDoneIsReady() {
        let count = EpicLane.taskCount(columns: [.done, .done])
        XCTAssertEqual(count.label, "2/2 done")
        XCTAssertTrue(count.readyForIntegration)
    }

    /// The pure count must agree with the store query the orchestrator gates on.
    func testReadyForIntegrationMatchesBoard() throws {
        let f = try Fixture.make()
        let (epic, _) = try f.board.createEpic(
            projectId: f.project.id, title: "Ship it", goal: nil,
            tasks: [NewEpicTask(title: "One"), NewEpicTask(title: "Two")]
        )
        func laneCount() throws -> EpicTaskCount {
            let tasks = try f.tasks.list(projectId: f.project.id, column: nil, epicId: epic.id)
            return EpicLane.taskCount(columns: tasks.map(\.column))
        }
        XCTAssertEqual(try laneCount().readyForIntegration, try f.board.epicReadyForIntegration(epicId: epic.id))

        for task in try f.tasks.list(projectId: f.project.id, column: nil, epicId: epic.id) {
            try f.tasks.move(task.id, to: .done)
        }
        XCTAssertTrue(try laneCount().readyForIntegration)
        XCTAssertEqual(try laneCount().readyForIntegration, try f.board.epicReadyForIntegration(epicId: epic.id))
    }

    func testRequestIntegrationShowsOnlyWhenEveryTaskIsDone() {
        func integration(_ state: EpicState, _ ready: Bool) -> Bool {
            EpicLane.actions(state: state, readyForIntegration: ready).contains(.requestIntegration)
        }
        XCTAssertFalse(integration(.active, false))
        XCTAssertTrue(integration(.active, true))
        XCTAssertTrue(integration(.planning, true))
        XCTAssertFalse(integration(.integrating, true))
        XCTAssertFalse(integration(.done, true))
        XCTAssertFalse(integration(.abandoned, true))
    }

    func testIntegratingOffersOnlyTheTwoWaysToEndTheEpic() {
        XCTAssertEqual(EpicLane.actions(state: .integrating, readyForIntegration: true), [.closeAsDone, .abandon])
    }

    func testAbandonedOffersNothing() {
        XCTAssertEqual(EpicLane.actions(state: .abandoned, readyForIntegration: true), [])
    }

    func testDoneShowsOnlyOpenPullRequest() {
        XCTAssertEqual(EpicLane.actions(state: .done, readyForIntegration: true), [.openPullRequest])
        XCTAssertEqual(EpicLane.actions(state: .done, readyForIntegration: false), [.openPullRequest])
    }

    /// The header draws at most one ordinary button; the two that end the epic live in a menu, so
    /// the lane never grows a destructive button beside a routine one.
    func testNoStateShowsMoreThanOneOrdinaryButton() {
        for state in EpicState.allCases {
            for ready in [true, false] {
                let ordinary = EpicLane.actions(state: state, readyForIntegration: ready).filter { $0.closure == nil }
                XCTAssertLessThanOrEqual(ordinary.count, 1, "\(state) ready=\(ready) showed \(ordinary)")
            }
        }
    }
}

final class RequestIntegrationTests: XCTestCase {
    func testCreatesOnePendingIntegrationApproval() throws {
        let f = try Fixture.make()
        let (epic, _) = try f.board.createEpic(projectId: f.project.id, title: "Ship it", goal: nil, tasks: [])

        let approval = try f.board.requestIntegration(epicId: epic.id, requestedBy: "human")
        XCTAssertEqual(approval.kind, .integration)
        XCTAssertEqual(approval.epicId, epic.id)
        XCTAssertNil(approval.taskId)
        XCTAssertTrue(approval.isPending)

        let pending = try ApprovalStore(f.db).pending(projectId: f.project.id)
        XCTAssertEqual(pending.map(\.id), [approval.id])
    }

    func testRepeatedRequestReturnsTheSamePendingRow() throws {
        let f = try Fixture.make()
        let (epic, _) = try f.board.createEpic(projectId: f.project.id, title: "Ship it", goal: nil, tasks: [])

        let first = try f.board.requestIntegration(epicId: epic.id, requestedBy: "human")
        let second = try f.board.requestIntegration(epicId: epic.id, requestedBy: "orchestrator")
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(try ApprovalStore(f.db).pending(projectId: f.project.id).count, 1)
    }

    func testUnknownEpicThrows() throws {
        let f = try Fixture.make()
        XCTAssertThrowsError(try f.board.requestIntegration(epicId: "nope", requestedBy: "human"))
    }
}
