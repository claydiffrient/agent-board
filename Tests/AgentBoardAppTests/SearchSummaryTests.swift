import XCTest
@testable import AgentBoard

final class SearchSummaryTests: XCTestCase {
    func testNoQuerySaysNothing() {
        XCTAssertNil(SearchSummary.text(query: "", shown: 3, total: 3, noun: .tasks))
        XCTAssertNil(SearchSummary.text(query: "  ", shown: 3, total: 3, noun: .tasks))
    }

    func testAnEmptyResultNamesTheQuery() {
        XCTAssertEqual(
            SearchSummary.text(query: " idle cap ", shown: 0, total: 41, noun: .tasks),
            "No tasks match “idle cap”"
        )
    }

    func testAResultCountsAgainstWhatTheScreenWouldShow() {
        XCTAssertEqual(SearchSummary.text(query: "idle", shown: 3, total: 41, noun: .tasks), "3 of 41 tasks")
        XCTAssertEqual(SearchSummary.text(query: "idle", shown: 1, total: 1, noun: .tasks), "1 of 1 task")
    }

    func testTheScreensNoteFollowsTheSummary() {
        XCTAssertEqual(
            SearchSummary.text(query: "idle", shown: 0, total: 4, noun: .tasks, note: "1 archived match hidden"),
            "No tasks match “idle” · 1 archived match hidden"
        )
    }

    func testThePromptNamesTheNoun() {
        XCTAssertEqual(SearchNoun.tasks.prompt, "Search tasks")
    }
}
