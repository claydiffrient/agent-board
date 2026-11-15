import AgentBoardCore
import XCTest

final class ConsoleSessionNameTests: XCTestCase {
    func testOrchestratorNameKeepsCaseAndCollapsesWhitespace() {
        XCTAssertEqual(ConsoleSessionName.orchestrator(projectName: "agent-board"), "agent-board-orchestrator")
        XCTAssertEqual(ConsoleSessionName.orchestrator(projectName: " My  Big\tApp "), "My-Big-App-orchestrator")
    }
}
