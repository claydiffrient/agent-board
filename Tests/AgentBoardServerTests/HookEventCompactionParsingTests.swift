import XCTest
@testable import AgentBoardServer

/// Both payloads are copied from the scratch `hook_event` table of a real `claude` run driven under
/// a PTY on 2026-09-15 (2.1.272), trimmed to the fields Agent Board reads. `source` and `trigger`
/// are what tell a compaction apart from a startup and a manual one apart from an automatic one.
final class HookEventCompactionParsingTests: XCTestCase {
    private func parse(_ json: String) throws -> HookEvent {
        try XCTUnwrap(HookEvent(body: XCTUnwrap(json.data(using: .utf8))))
    }

    func testSessionStartCarriesItsSource() throws {
        let event = try parse(#"""
        {"session_id":"401e21d5-0000-0000-0000-000000000000",
         "transcript_path":"/Users/x/.claude/projects/-tmp-repo/401e21d5.jsonl",
         "cwd":"/tmp/repo","hook_event_name":"SessionStart","source":"compact","model":"claude-fable-5-1"}
        """#)

        XCTAssertEqual(event.name, "SessionStart")
        XCTAssertEqual(event.sessionSource, "compact")
        XCTAssertEqual(event.sessionId, "401e21d5-0000-0000-0000-000000000000")
        XCTAssertNil(event.compactTrigger)
    }

    func testAStartupSessionStartIsNotACompaction() throws {
        let event = try parse(#"{"session_id":"s","hook_event_name":"SessionStart","source":"startup"}"#)
        XCTAssertEqual(event.sessionSource, "startup")
    }

    func testPreCompactCarriesItsTrigger() throws {
        let manual = try parse(#"{"session_id":"s","hook_event_name":"PreCompact","trigger":"manual","custom_instructions":null}"#)
        XCTAssertEqual(manual.compactTrigger, "manual")
        XCTAssertNil(manual.sessionSource)

        let auto = try parse(#"{"session_id":"s","hook_event_name":"PreCompact","trigger":"auto","custom_instructions":null}"#)
        XCTAssertEqual(auto.compactTrigger, "auto")
    }

    func testAnEventWithNeitherFieldParsesWithBothNil() throws {
        let event = try parse(#"{"session_id":"s","hook_event_name":"Stop","stop_hook_active":false}"#)
        XCTAssertNil(event.sessionSource)
        XCTAssertNil(event.compactTrigger)
    }
}
