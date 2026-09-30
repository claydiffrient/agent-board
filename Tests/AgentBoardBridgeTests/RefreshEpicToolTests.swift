import AgentBoardBridge
import AgentBoardCore
import AgentBoardServer
import Foundation
import XCTest

final class RefreshEpicToolTests: XCTestCase {
    func testAClosedEpicIsRefusedBeforeAnythingTouchesItsBranch() async throws {
        let f = try BridgeFixture.make()
        for state in [EpicState.done, .abandoned] {
            let epic = try f.epic("Closed", state: state)
            await XCTAssertToolError(
                try await f.call("refresh_epic", ["epic_id": .string(epic.id)]),
                containing: "is \(state.rawValue): it is closed, so its branch is not refreshed"
            )
        }
        let refreshed = await f.control.refreshed
        XCTAssertEqual(refreshed, [], "a closed epic's refresh reached the supervisor")
    }
}
