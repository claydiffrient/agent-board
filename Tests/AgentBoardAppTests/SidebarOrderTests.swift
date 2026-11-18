import XCTest
@testable import AgentBoard

/// SPEC §10: the sidebar draws its pinned rows from `SidebarSelection.pinned(showingReviews:)`, in this order.
final class SidebarOrderTests: XCTestCase {
    func testInboxSitsBelowAtAGlanceAndPullRequestsBelowCoordinator() {
        XCTAssertEqual(SidebarSelection.pinned, [.atAGlance, .inbox, .roster, .coordinator, .pullRequests])
        XCTAssertEqual(SidebarSelection.pinned(showingReviews: false), SidebarSelection.pinned)
        XCTAssertEqual(
            SidebarSelection.pinned(showingReviews: true),
            [.atAGlance, .inbox, .roster, .coordinator, .pullRequests, .reviews]
        )
    }
}
