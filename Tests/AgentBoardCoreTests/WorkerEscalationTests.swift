import XCTest
@testable import AgentBoardCore

/// SPEC §5 retries: Opus moves up to Fable only when the project allows it.
final class WorkerEscalationTests: XCTestCase {
    func testOpusAtExtraHighMovesToFableOnlyWithTheSettingOn() {
        let resolved = WorkerModelChoice(
            model: "claude-opus-5-5", modelSource: .typeTable, effort: .medium, effortSource: .typeTable
        )
        let prior = WorkerEscalation.Prior(attempt: 3, model: "claude-opus-5-5", effort: .xhigh, shortfall: .failed)

        let off = WorkerEscalation.escalate(resolved, after: prior, attempt: 4, allowsFable: false)
        XCTAssertEqual(off.model, "claude-opus-5-5")
        XCTAssertEqual(off.effort, .xhigh, "the top of the ladder keeps the effort the last attempt reached")

        let on = WorkerEscalation.escalate(resolved, after: prior, attempt: 4, allowsFable: true)
        XCTAssertEqual(on.model, "claude-fable-5-2")
        XCTAssertEqual(on.effort, .medium)
    }
}
