import AgentBoardCore
import AgentBoardRuntime
import Foundation
import XCTest
@testable import AgentBoard

/// The order gates every path that starts a worker, including the approvals a human clicks through.
@MainActor
final class ShutdownOrderTests: XCTestCase {
    private var fixture: SupervisorFixture!

    override func setUp() async throws {
        fixture = try SupervisorFixture.make(gitRepo: true)
        await fixture.supervisor.start()
        try XCTSkipIf(fixture.supervisor.serverPort == nil, "the board server could not bind a port")
    }

    override func tearDown() async throws {
        await fixture.cleanUp()
        fixture = nil
    }

    private func readyTask(_ title: String = "Do the thing") throws -> BoardTask {
        try fixture.tasks.create(
            projectId: fixture.project.id, title: title, body: nil, acceptance: nil, priority: nil,
            column: .ready, origin: .human, epicId: nil
        )
    }

    private func order() async throws {
        try await fixture.supervisor.requestShutdown(projectId: fixture.project.id, requestedBy: "human", reason: nil)
    }

    private func assertShutdownRefusal(_ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected a shutdown refusal")
        } catch {
            XCTAssertEqual((error as? SupervisorError)?.errorDescription, ShutdownOrder.refusal)
        }
    }

    func testAssignRefusesWhileAnOrderIsOutstandingAndSpawnsNothing() async throws {
        let task = try readyTask()
        try await order()

        await assertShutdownRefusal { try await self.fixture.supervisor.assign(taskId: task.id) }

        let spawns = await fixture.runtime.spawns
        XCTAssertEqual(spawns.count, 0)
        XCTAssertEqual(try fixture.tasks.get(task.id)?.column, .ready)
        XCTAssertEqual(try fixture.sessions.all(projectId: fixture.project.id).count, 0)
    }

    func testApprovingAPendingSpawnRefusesAndLeavesTheApprovalPending() async throws {
        let task = try readyTask()
        guard case .approvalPending(let approval) = try fixture.board.requestSpawn(taskId: task.id, requestedBy: "orch") else {
            return XCTFail("expected a pending spawn approval")
        }
        try await order()

        await assertShutdownRefusal { try await self.fixture.supervisor.approve(approvalId: approval.id) }

        XCTAssertEqual(try fixture.approvals.get(approval.id)?.isPending, true)
        XCTAssertEqual(try fixture.approvals.pending(projectId: fixture.project.id).map(\.id), [approval.id])
        let spawns = await fixture.runtime.spawns
        XCTAssertEqual(spawns.count, 0)

        try await fixture.supervisor.cancelShutdown(projectId: fixture.project.id, by: "human")
        try await fixture.supervisor.approve(approvalId: approval.id)
        await fixture.supervisor.waitForSetup()

        XCTAssertEqual(try fixture.approvals.get(approval.id)?.resolution, .approved)
        let afterCancel = await fixture.runtime.spawns
        XCTAssertEqual(afterCancel.count, 1)
    }

    /// An integrator is a worker, so its approval is gated too (§5.2 step 3).
    func testApprovingAPendingIntegrationRefusesAndLeavesTheApprovalPending() async throws {
        let (epic, _) = try fixture.epicReadyForIntegration(["one"])
        let approval = try fixture.board.requestIntegration(epicId: epic.id, requestedBy: "orch")
        try await order()

        await assertShutdownRefusal { try await self.fixture.supervisor.approve(approvalId: approval.id) }

        XCTAssertEqual(try fixture.approvals.get(approval.id)?.isPending, true)
        XCTAssertEqual(try fixture.epics.get(epic.id)?.state, .active, "the epic did not move to integrating")
        let spawns = await fixture.runtime.spawns
        XCTAssertEqual(spawns.count, 0)
    }
}
