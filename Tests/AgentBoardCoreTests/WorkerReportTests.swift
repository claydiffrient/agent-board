import XCTest
@testable import AgentBoardCore

final class WorkerReportTests: XCTestCase {
    private let realBody = """
    {
      "caveats" : "The GUI was not exercised; only the parse is covered by tests.",
      "files_changed" : [
        "Sources/AgentBoard/Views/Orchestrator/ApprovalsSidebar.swift",
        "Sources/AgentBoardRuntime/WorktreeManager.swift"
      ],
      "summary" : "Reworked the Pending Reviews row to show a one-line change size. The raw diffstat and worktree path are gone. Report bodies are decoded instead of dumped as JSON. A fourth sentence that should not survive truncation.",
      "tests_run" : "swift test: 142 passed"
    }
    """

    func testDecodesRealReportCompleteBody() throws {
        let report = try XCTUnwrap(WorkerReport.decode(body: realBody))
        XCTAssertEqual(report.filesChanged.count, 2)
        XCTAssertEqual(report.testsRun, "swift test: 142 passed")
        XCTAssertTrue(report.summary.hasPrefix("Reworked the Pending Reviews row"))
    }

    func testSummaryTextTakesOnlyTheSummaryField() {
        let text = WorkerReport.summaryText(body: realBody)
        XCTAssertFalse(text.contains("caveats"))
        XCTAssertFalse(text.contains("{"))
        XCTAssertEqual(
            text,
            "Reworked the Pending Reviews row to show a one-line change size. The raw diffstat and worktree path are gone. Report bodies are decoded instead of dumped as JSON."
        )
    }

    func testMalformedJSONFallsBackToTheRawBody() {
        let broken = "{ \"summary\" : \"truncated mid-write"
        XCTAssertNil(WorkerReport.decode(body: broken))
        XCTAssertEqual(WorkerReport.summaryText(body: broken), broken)
    }

    func testPlainProseBodyFallsBackAndStillTruncates() {
        let prose = "One. Two. Three. Four."
        XCTAssertEqual(WorkerReport.summaryText(body: prose), "One. Two. Three.")
    }

    func testBodyMissingSummaryFieldFallsBack() {
        let body = "{\"files_changed\":[],\"tests_run\":\"none\"}"
        XCTAssertNil(WorkerReport.decode(body: body))
        XCTAssertEqual(WorkerReport.summaryText(body: body), body)
    }

    func testOptionalFieldsDefaultWhenAbsent() throws {
        let report = try XCTUnwrap(WorkerReport.decode(body: "{\"summary\":\"Just a summary.\"}"))
        XCTAssertEqual(report.filesChanged, [])
        XCTAssertEqual(report.testsRun, "")
        XCTAssertEqual(report.caveats, "")
    }

    func testFewerSentencesThanLimitReturnsWholeText() {
        XCTAssertEqual(WorkerReport.firstSentences(of: "Only one sentence.", limit: 3), "Only one sentence.")
        XCTAssertEqual(WorkerReport.firstSentences(of: "No terminator at all", limit: 3), "No terminator at all")
    }

    func testDecimalsAndVersionsDoNotEndASentence() {
        let text = "Bumped GRDB to 7.0.1 and Hummingbird to 2.1.0 in Package.swift. Second. Third. Fourth."
        XCTAssertEqual(
            WorkerReport.firstSentences(of: text, limit: 3),
            "Bumped GRDB to 7.0.1 and Hummingbird to 2.1.0 in Package.swift. Second. Third."
        )
    }
}
