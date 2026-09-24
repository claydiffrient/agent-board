import XCTest
@testable import AgentBoardCore

final class TaskSearchTests: XCTestCase {
    private func task(
        _ id: String, title: String, body: String? = nil, acceptance: String? = nil, epicId: String? = nil,
        model: String? = nil, rosterAgentId: String? = nil, reviewerAgentId: String? = nil
    ) -> BoardTask {
        BoardTask(
            id: id, projectId: "p", epicId: epicId, title: title, body: body, acceptance: acceptance,
            priority: nil, column: .ready, ordering: 0, origin: .human, createdAt: 0, updatedAt: 0,
            model: model, reviewerAgentId: reviewerAgentId, rosterAgentId: rosterAgentId
        )
    }

    private func matching(_ text: String, in tasks: [BoardTask]) -> [String] {
        TaskSearch.filter(
            tasks, query: SearchQuery(text),
            epicTitles: ["e-search": "Search everywhere"],
            agentNames: ["a-fran": "Fran", "a-rita": "Rita"]
        ).map(\.id)
    }

    func testAnEmptyOrBlankQueryKeepsEveryTaskInOrder() {
        let tasks = [task("b", title: "Beta"), task("a", title: "Alpha")]
        XCTAssertEqual(matching("", in: tasks), ["b", "a"])
        XCTAssertEqual(matching("  \t ", in: tasks), ["b", "a"])
        XCTAssertTrue(SearchQuery(" \n").isEmpty)
    }

    func testEachFieldIsReached() {
        let tasks = [
            task("title", title: "Idle cap watchdog"),
            task("body", title: "x", body: "Stop the worker once the idle cap trips"),
            task("acceptance", title: "x", acceptance: "The idle cap fires after 30 minutes"),
            task("epic", title: "x", epicId: "e-search"),
            task("model-id", title: "x", model: "claude-haiku-4-5-20251001"),
            task("agent", title: "x", rosterAgentId: "a-fran"),
            task("reviewer", title: "x", reviewerAgentId: "a-rita"),
            task("none", title: "Unrelated", body: "Nothing here"),
        ]
        XCTAssertEqual(matching("idle cap", in: tasks), ["title", "body", "acceptance"])
        XCTAssertEqual(matching("everywhere", in: tasks), ["epic"])
        XCTAssertEqual(matching("haiku 4.5", in: tasks), ["model-id"], "the display name of a dated id")
        XCTAssertEqual(matching("20251001", in: tasks), ["model-id"], "the raw model id")
        XCTAssertEqual(matching("fran", in: tasks), ["agent"])
        XCTAssertEqual(matching("rita", in: tasks), ["reviewer"])
    }

    func testTermsMayMatchDifferentFieldsButAllMustMatch() {
        let tasks = [
            task("split", title: "Idle timeout", body: "raise the cap"),
            task("half", title: "Idle timeout"),
        ]
        XCTAssertEqual(matching("idle cap", in: tasks), ["split"])
    }

    func testMatchingIgnoresCaseAndDiacritics() {
        let tasks = [task("cafe", title: "Café résumé export")]
        XCTAssertEqual(matching("CAFE RESUME", in: tasks), ["cafe"])
    }

    func testAnUnknownEpicOrAgentIdMatchesNothingRatherThanTheId() {
        let tasks = [task("t", title: "x", epicId: "e-gone", rosterAgentId: "a-gone")]
        XCTAssertEqual(matching("gone", in: tasks), [])
    }

    func testTheTaskIdIsNotSearched() {
        let tasks = [task("badface-0000", title: "Port sweep")]
        XCTAssertEqual(matching("badface", in: tasks), [])
    }

    func testNarrowingKeepsArchivedMatchesHiddenButCountsThem() {
        var archived = task("old", title: "Idle cap v1")
        archived.archivedAt = 5
        let live = task("live", title: "Idle cap v2")
        let other = task("other", title: "Port sweep")
        let partition = TaskArchive.partition([archived, live, other], showArchived: false)
        let narrowed = TaskSearch.narrow(partition, query: SearchQuery("idle"), epicTitles: [:], agentNames: [:])
        XCTAssertEqual(narrowed.visible.map(\.id), ["live"])
        XCTAssertEqual(narrowed.hidden.map(\.id), ["old"])

        let shown = TaskArchive.partition([archived, live, other], showArchived: true)
        let reached = TaskSearch.narrow(shown, query: SearchQuery("idle"), epicTitles: [:], agentNames: [:])
        XCTAssertEqual(reached.visible.map(\.id), ["old", "live"], "with Show Archived on, search reaches them")
    }

    func testTheHiddenMatchesNote() {
        XCTAssertNil(TaskSearch.hiddenMatchesNote(count: 0))
        XCTAssertEqual(TaskSearch.hiddenMatchesNote(count: 1), "1 archived match hidden")
        XCTAssertEqual(TaskSearch.hiddenMatchesNote(count: 3), "3 archived matches hidden")
    }
}
