import XCTest
@testable import AgentBoard

final class ProjectScreenOrderTests: XCTestCase {
    func testOrchestratorIsTheFirstSegment() {
        XCTAssertEqual(ProjectDetailView.Screen.allCases.first, .orchestrator)
    }

    func testProjectOpensOnOrchestrator() {
        XCTAssertEqual(ProjectDetailView.defaultScreen, .orchestrator)
    }

    func testRemainingScreensKeepTheirOrder() {
        XCTAssertEqual(
            ProjectDetailView.Screen.allCases.map(\.rawValue),
            ["Orchestrator", "Task Board", "Status", "Notes"]
        )
    }
}
