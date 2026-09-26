import XCTest
@testable import AgentBoard

/// SPEC §10: the sidebar draws its pinned rows from `SidebarSelection.pinned`, in this order.
final class SidebarOrderTests: XCTestCase {
    func testCoordinatorSitsDirectlyBelowRoster() {
        XCTAssertEqual(SidebarSelection.pinned, [.atAGlance, .roster, .coordinator])
    }
}
