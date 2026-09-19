import AgentBoardBridge
import AgentBoardCore
import AgentBoardServer
import XCTest

/// `propose_task(epic_id)`: a planning worker puts its tickets in the epic it is planning, and the
/// epic is checked both when the proposal is written and again when it is promoted. SPEC §5.
final class ProposalEpicToolTests: XCTestCase {
    private var f: BridgeFixture!

    override func setUpWithError() throws {
        f = try BridgeFixture.make()
        try f.setAutonomy(true)
    }

    private func worker(epicId: String? = nil) throws -> TokenIdentity {
        let task = try f.task("Plan out remaining tickets", column: .running, epicId: epicId)
        try f.worktreeSession("s1", taskId: task.id)
        return f.workerIdentity(sessionId: "s1", taskId: task.id)
    }

    func testGetMyTaskReportsTheEpicTheTaskIsIn() async throws {
        let epic = try f.epic("User guide")
        let payload = try await f.callJSON("get_my_task", as: try worker(epicId: epic.id))
        XCTAssertEqual(payload["epic_id"]?.stringValue, epic.id)
    }

    func testGetMyTaskReportsNoEpicForAStandaloneTask() async throws {
        let payload = try await f.callJSON("get_my_task", as: try worker())
        XCTAssertEqual(payload["epic_id"], .null)
    }

    func testProposalNamingAnEpicLandsInItWhenPromoted() async throws {
        let epic = try f.epic("User guide")
        let identity = try worker(epicId: epic.id)
        let proposed = try await f.callJSON(
            "propose_task", ["title": .string("Write the install page"), "epic_id": .string(epic.id)], as: identity
        )
        let id = try XCTUnwrap(proposed["id"]?.stringValue)
        XCTAssertEqual(proposed["epic_id"]?.stringValue, epic.id)
        XCTAssertEqual(try f.tasks.get(id)?.epicId, epic.id, "the proposal carries the epic while it waits")

        let result = try await f.call("promote_proposal", ["task_id": .string(id)])
        XCTAssertEqual(try f.tasks.get(id)?.epicId, epic.id)
        XCTAssertEqual(try f.tasks.get(id)?.column, .ready)
        XCTAssertTrue(result.text.contains(epic.id), result.text)
    }

    func testProposalNamingNoEpicBehavesAsBefore() async throws {
        let epic = try f.epic("User guide")
        let identity = try worker(epicId: epic.id)
        let proposed = try await f.callJSON("propose_task", ["title": .string("Something else")], as: identity)
        let id = try XCTUnwrap(proposed["id"]?.stringValue)
        XCTAssertEqual(proposed["column"]?.stringValue, "proposed")
        XCTAssertEqual(proposed["epic_id"], .null, "the task's own epic is never assumed")
        XCTAssertNil(try f.tasks.get(id)?.epicId)

        _ = try await f.call("promote_proposal", ["task_id": .string(id)])
        XCTAssertNil(try f.tasks.get(id)?.epicId)
        XCTAssertEqual(try f.tasks.get(id)?.column, .ready)
    }

    func testProposalMayNameAnyLiveEpicInTheSameProject() async throws {
        let sibling = try f.epic("Notifications")
        let identity = try worker(epicId: try f.epic("User guide").id)
        let proposed = try await f.callJSON(
            "propose_task", ["title": .string("Cross-cut"), "epic_id": .string(sibling.id)], as: identity
        )
        XCTAssertEqual(proposed["epic_id"]?.stringValue, sibling.id)
    }

    func testAnEpicInAnotherProjectIsRefused() async throws {
        let foreign = try f.epic("Theirs", in: try f.otherProject().id)
        await XCTAssertToolError(
            try await f.call("propose_task", ["title": .string("x"), "epic_id": .string(foreign.id)], as: try worker()),
            containing: "belongs to another project"
        )
    }

    func testAnEpicThatDoesNotExistIsRefused() async throws {
        await XCTAssertToolError(
            try await f.call("propose_task", ["title": .string("x"), "epic_id": .string("nope")], as: try worker()),
            containing: "does not exist"
        )
    }

    func testADoneEpicIsRefusedAtProposeTime() async throws {
        let closed = try f.epic("Finished", state: .done)
        await XCTAssertToolError(
            try await f.call("propose_task", ["title": .string("x"), "epic_id": .string(closed.id)], as: try worker()),
            containing: "is already done"
        )
        XCTAssertEqual(try f.tasks.list(projectId: f.project.id, column: .proposed).count, 0)
    }

    func testAnEpicThatFinishesWhileTheProposalWaitsPromotesIntoNoEpic() async throws {
        let epic = try f.epic("User guide")
        let identity = try worker(epicId: epic.id)
        let proposed = try await f.callJSON(
            "propose_task", ["title": .string("Write the install page"), "epic_id": .string(epic.id)], as: identity
        )
        let id = try XCTUnwrap(proposed["id"]?.stringValue)
        try EpicStore(f.db).setState(epic.id, .done)

        let result = try await f.call("promote_proposal", ["task_id": .string(id)])
        XCTAssertNil(try f.tasks.get(id)?.epicId, "a finished epic never takes an unfinished task")
        XCTAssertEqual(try f.tasks.get(id)?.column, .ready, "the promotion still happens")
        XCTAssertTrue(result.text.contains("promoted into no epic"), result.text)
        XCTAssertTrue(result.text.contains("is already done"), result.text)

        let decision = try XCTUnwrap(f.reports.unconsumed(projectId: f.project.id).last)
        XCTAssertTrue(decision.body.contains("promoted into no epic"), decision.body)
    }
}
