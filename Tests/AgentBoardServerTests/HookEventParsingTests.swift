import Foundation
import XCTest
@testable import AgentBoardServer

final class HookEventParsingTests: XCTestCase {
    private func parse(_ object: [String: Any]) throws -> HookEvent {
        try XCTUnwrap(HookEvent(body: try JSONSerialization.data(withJSONObject: object)))
    }

    func testPreCompactCarriesItsTrigger() throws {
        let auto = try parse([
            "hook_event_name": "PreCompact", "session_id": "s1",
            "trigger": "auto", "custom_instructions": NSNull(),
        ])
        XCTAssertEqual(auto.name, "PreCompact")
        XCTAssertEqual(auto.compactTrigger, "auto")

        let manual = try parse(["hook_event_name": "PreCompact", "session_id": "s1", "trigger": "manual"])
        XCTAssertEqual(manual.compactTrigger, "manual")
    }

    func testSubagentStopCarriesItsAgentType() throws {
        let event = try parse([
            "hook_event_name": "SubagentStop", "session_id": "s1",
            "agent_id": "a1", "agent_type": "Explore",
        ])
        XCTAssertEqual(event.name, "SubagentStop")
        XCTAssertEqual(event.agentType, "Explore")
        XCTAssertNil(event.compactTrigger)
    }

    func testAContextOnlyResponseCarriesNoVerdict() throws {
        let body = HookDecision.context("your task is still open").responseBody(hookEventName: "PostToolUse")
        let specific = try XCTUnwrap(body["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(specific["hookEventName"] as? String, "PostToolUse")
        XCTAssertEqual(specific["additionalContext"] as? String, "your task is still open")
        XCTAssertNil(specific["permissionDecision"])
        XCTAssertNil(body["decision"])
        XCTAssertNil(body["reason"])
    }
}
