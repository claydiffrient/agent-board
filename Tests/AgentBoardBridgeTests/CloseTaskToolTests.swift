import AgentBoardBridge
import AgentBoardCore
import AgentBoardServer
import Foundation
import XCTest

final class CloseTaskToolTests: XCTestCase {
    private var f: BridgeFixture!

    override func setUpWithError() throws {
        f = try BridgeFixture.make()
    }

    func testCloseTaskRecordsTheReasonNamesDependentsAndOnlyAHumanReopens() async throws {
        let obsolete = try f.task("Design the theme toggle in Paper", column: .ready)
        let dependent = try f.task("Build the theme toggle")
        try f.tasks.setDeps(dependent.id, dependsOn: [obsolete.id])

        let answer = try await f.call("close_task", [
            "task_id": .string(obsolete.id), "reason": .string("Designed in the orchestrator session; approved"),
        ])
        XCTAssertTrue(answer.text.contains(dependent.id), answer.text)

        let detail = try await f.callJSON("get_task", ["id": .string(obsolete.id)])
        XCTAssertEqual(detail["column"], .string("closed"))
        XCTAssertEqual(detail["closed_reason"], .string("Designed in the orchestrator session; approved"))

        await XCTAssertToolError(
            try await f.call("move_task", ["id": .string(obsolete.id), "column": .string("ready")]),
            containing: "Only a human reopens"
        )
        await XCTAssertToolError(
            try await f.call("close_task", ["task_id": .string(obsolete.id), "reason": .string("again")]),
            containing: "already closed"
        )
    }
}
