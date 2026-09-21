import AgentBoardCore
import XCTest

@testable import AgentBoard

/// The human's own Promote button, which goes through `WorkerSupervisor.promote` rather than the
/// orchestrator's `promote_proposal`. Both must honour the epic a proposal named. SPEC §5.
@MainActor
final class PromoteProposalEpicTests: XCTestCase {
    private var f: SupervisorFixture!

    override func setUpWithError() throws {
        f = try SupervisorFixture.make()
    }

    private func epic(_ title: String, state: EpicState = .active) throws -> Epic {
        let epic = try f.epics.create(projectId: f.project.id, title: title, goal: nil)
        if state != .planning { try f.epics.setState(epic.id, state) }
        return try XCTUnwrap(f.epics.get(epic.id))
    }

    func testPromotingThroughTheAppLandsTheTaskInTheProposedEpic() async throws {
        let epic = try epic("User guide")
        let proposal = try f.board.propose(
            projectId: f.project.id, title: "Write the install page", body: nil, rationale: nil,
            sessionId: nil, epicId: epic.id
        )

        try await f.supervisor.promote(taskId: proposal.id)

        XCTAssertEqual(try f.tasks.get(proposal.id)?.epicId, epic.id)
        XCTAssertEqual(try f.tasks.get(proposal.id)?.column, .ready)
    }

    func testPromotingAProposalWithNoEpicThroughTheAppLeavesItOutsideEveryEpic() async throws {
        let proposal = try f.board.propose(
            projectId: f.project.id, title: "Standalone", body: nil, rationale: nil, sessionId: nil, epicId: nil
        )

        try await f.supervisor.promote(taskId: proposal.id)

        XCTAssertNil(try f.tasks.get(proposal.id)?.epicId)
        XCTAssertEqual(try f.tasks.get(proposal.id)?.column, .ready)
    }

    func testPromotingThroughTheAppIntoAnEpicThatFinishedLandsInNoEpic() async throws {
        let epic = try epic("User guide")
        let proposal = try f.board.propose(
            projectId: f.project.id, title: "Write the install page", body: nil, rationale: nil,
            sessionId: nil, epicId: epic.id
        )
        try f.epics.setState(epic.id, .done)

        try await f.supervisor.promote(taskId: proposal.id)

        XCTAssertNil(try f.tasks.get(proposal.id)?.epicId)
        XCTAssertEqual(try f.tasks.get(proposal.id)?.column, .ready)
        let decision = try XCTUnwrap(f.reports.unconsumed(projectId: f.project.id).last)
        XCTAssertTrue(decision.body.contains("promoted into no epic"), decision.body)
    }
}
