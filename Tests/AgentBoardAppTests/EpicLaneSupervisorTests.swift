import AgentBoardCore
import XCTest
@testable import AgentBoard

@MainActor
final class EpicLaneSupervisorTests: XCTestCase {
    func testRequestIntegrationQueuesOneApprovalAndSpawnsNothing() async throws {
        let f = try SupervisorFixture.make()
        defer { f.cleanUp() }
        let (epic, _) = try Board(f.db).createEpic(
            projectId: f.project.id, title: "Ship it", goal: nil, tasks: [NewEpicTask(title: "One")]
        )

        try await f.supervisor.requestIntegration(epicId: epic.id)
        try await f.supervisor.requestIntegration(epicId: epic.id)

        let pending = try ApprovalStore(f.db).pending(projectId: f.project.id)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.kind, .integration)
        XCTAssertEqual(pending.first?.epicId, epic.id)
        XCTAssertEqual(try f.sessions.all(projectId: f.project.id).count, 0)
    }

    func testRequestIntegrationOnAnUnknownEpicFails() async throws {
        let f = try SupervisorFixture.make()
        defer { f.cleanUp() }
        do {
            try await f.supervisor.requestIntegration(epicId: "nope")
            XCTFail("expected a failure for an unknown epic")
        } catch {
            XCTAssertTrue(errorText(error).contains("nope"), errorText(error))
        }
    }

    func testBlankDraftRowsAreDroppedAndFilledOnesCarryEveryField() {
        var filled = EpicTaskDraft()
        filled.title = "  Wire the picker  "
        filled.body = "Body text"
        filled.acceptance = "It works"
        filled.priority = "high"
        filled.model = "claude-opus-5"

        let specs = EpicTaskDraft.specs(from: [EpicTaskDraft(), filled, EpicTaskDraft()])
        XCTAssertEqual(specs.count, 1)
        XCTAssertEqual(specs.first?.title, "Wire the picker")
        XCTAssertEqual(specs.first?.body, "Body text")
        XCTAssertEqual(specs.first?.acceptance, "It works")
        XCTAssertEqual(specs.first?.priority, "high")
        XCTAssertEqual(specs.first?.model, "claude-opus-5")
        XCTAssertEqual(specs.first?.origin, .human)
    }

    func testEmptyOptionalFieldsBecomeNilRatherThanEmptyStrings() {
        var draft = EpicTaskDraft()
        draft.title = "Bare"
        let spec = EpicTaskDraft.specs(from: [draft]).first
        XCTAssertNil(spec?.body)
        XCTAssertNil(spec?.acceptance)
        XCTAssertNil(spec?.priority)
        XCTAssertNil(spec?.model)
    }
}
