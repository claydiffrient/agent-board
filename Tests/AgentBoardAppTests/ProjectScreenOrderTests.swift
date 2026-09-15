import XCTest
@testable import AgentBoard

final class ProjectScreenOrderTests: XCTestCase {
    func testOrchestratorIsTheFirstSegment() {
        XCTAssertEqual(ProjectDetailView.Screen.allCases.first, .orchestrator)
    }

    func testProjectOpensOnOrchestrator() {
        XCTAssertEqual(ProjectDetailView.defaultScreen, .orchestrator)
    }

    /// Terminal sits beside Orchestrator because both are live consoles you type into; Task Board,
    /// Status and Notes are the board's read surfaces. The control reads as two groups, not five peers.
    func testTerminalFollowsOrchestratorAndPrecedesTheBoardScreens() {
        let order = ProjectDetailView.Screen.allCases
        XCTAssertEqual(order.firstIndex(of: .terminal), 1)
        XCTAssertLessThan(order.firstIndex(of: .terminal)!, order.firstIndex(of: .board)!)
    }

    func testRemainingScreensKeepTheirOrder() {
        XCTAssertEqual(
            ProjectDetailView.Screen.allCases.map(\.rawValue),
            ["Orchestrator", "Terminal", "Task Board", "Status", "Notes"]
        )
    }
}
