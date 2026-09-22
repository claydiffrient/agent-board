import XCTest
@testable import AgentBoardCore

final class ContextPressureTests: XCTestCase {
    private let limit = 980_000

    private func pressure(_ used: Int) -> ContextPressure {
        ContextPressure(usedTokens: used, limitTokens: limit)
    }

    // MARK: - The threshold and either side of it

    func testExactlyAtTheThresholdCompacts() {
        let atThreshold = Int(OrchestratorCompaction.threshold * Double(limit))
        XCTAssertEqual(atThreshold, 784_000)
        XCTAssertTrue(pressure(atThreshold).exceeds(OrchestratorCompaction.threshold))
    }

    func testOneTokenUnderTheThresholdDoesNotCompact() {
        XCTAssertFalse(pressure(783_999).exceeds(OrchestratorCompaction.threshold))
    }

    func testOneTokenOverTheThresholdCompacts() {
        XCTAssertTrue(pressure(784_001).exceeds(OrchestratorCompaction.threshold))
    }

    func testAnEmptyContextDoesNotCompact() {
        XCTAssertFalse(pressure(0).exceeds(OrchestratorCompaction.threshold))
    }

    /// Agent Board has to fire before Claude Code's own trigger or it never gets to choose the
    /// moment; that trigger is `effectiveWindow - 33000` (SPEC §2).
    func testTheThresholdIsBelowClaudeCodesOwnAutoCompaction() {
        let claudeCodeTrigger = limit - 33_000
        XCTAssertLessThan(Int(OrchestratorCompaction.threshold * Double(limit)), claudeCodeTrigger)
    }

    func testFractionAndPercent() {
        XCTAssertEqual(pressure(490_000).fraction, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(pressure(490_000).percent, 50)
        XCTAssertEqual(pressure(784_000).percent, 80)
    }

    /// A session whose model is unknown would otherwise divide by zero and compact forever.
    func testAZeroLimitNeverCompacts() {
        let unknown = ContextPressure(usedTokens: 900_000, limitTokens: 0)
        XCTAssertEqual(unknown.fraction, 0)
        XCTAssertFalse(unknown.exceeds(OrchestratorCompaction.threshold))
    }

    // MARK: - Where the limit comes from

    func testMeasuredModelsCarryTheWindowClaudeCodeBudgetsAgainst() {
        XCTAssertEqual(ModelCatalog.effectiveContextWindow(for: "claude-fable-5-1"), 980_000)
        XCTAssertEqual(ModelCatalog.effectiveContextWindow(for: "claude-opus-5"), 980_000)
        XCTAssertEqual(ModelCatalog.effectiveContextWindow(for: "claude-sonnet-5"), 980_000)
    }

    /// Opus 5.5's window happens to equal Opus 5's, so the entry is pinned rather than the number.
    func testOpus55ResolvesToItsOwnEntryNotOpus5s() {
        XCTAssertEqual(ModelCatalog.option(for: "claude-opus-5-5")?.id, "claude-opus-5-5")
        XCTAssertEqual(ModelCatalog.option(for: "claude-opus-5-5-20260101")?.id, "claude-opus-5-5")
        XCTAssertEqual(ModelCatalog.option(for: "claude-opus-5")?.id, "claude-opus-5")
        XCTAssertEqual(ModelCatalog.option(for: "claude-opus-5-20260101")?.id, "claude-opus-5")
        XCTAssertEqual(ModelCatalog.effectiveContextWindow(for: "claude-opus-5-5"), 980_000)
    }

    func testADatedModelIdResolvesToItsCatalogEntry() {
        XCTAssertEqual(
            ModelCatalog.effectiveContextWindow(for: "claude-haiku-4-5-20251001"),
            ModelCatalog.fallbackContextWindow
        )
    }

    func testAnUnknownOrAbsentModelFallsBackRatherThanReadingZero() {
        XCTAssertEqual(ModelCatalog.effectiveContextWindow(for: nil), ModelCatalog.fallbackContextWindow)
        XCTAssertEqual(ModelCatalog.effectiveContextWindow(for: ""), ModelCatalog.fallbackContextWindow)
        XCTAssertEqual(ModelCatalog.effectiveContextWindow(for: "some-future-model"), ModelCatalog.fallbackContextWindow)
    }

    // MARK: - The app-authored lines (D9)

    /// Claude Code's slash-command autocomplete swallows a carriage return that arrives in the same
    /// write as the command text, leaving a literal `^M` in the prompt (measured, SPEC §2). The
    /// console sends the terminator separately, so the constant must not carry one.
    func testTheCompactionCommandCarriesNoTerminator() {
        XCTAssertTrue(OrchestratorCompaction.command.hasPrefix("/compact "))
        XCTAssertFalse(OrchestratorCompaction.command.contains("\r"))
        XCTAssertFalse(OrchestratorCompaction.command.contains("\n"))
    }

    func testTheReorientationLineIsOneLineAndNamesTheBoardTools() {
        let line = OrchestratorCompaction.reorientation
        XCTAssertFalse(line.contains("\r"))
        XCTAssertFalse(line.contains("\n"))
        XCTAssertTrue(line.contains("list_tasks"))
        XCTAssertTrue(line.contains("list_agents"))
        XCTAssertTrue(line.contains("list_reports"))
    }

    /// The default summariser keeps the narrative and drops the decisions, which is backwards for a
    /// session whose narrative is re-readable from SQLite.
    func testTheCompactionInstructionsKeepDecisionsAndDropEnumerations() {
        let instructions = OrchestratorCompaction.instructions
        XCTAssertTrue(instructions.contains("Standing instructions from the human"))
        XCTAssertTrue(instructions.contains("still unanswered"))
        XCTAssertTrue(instructions.contains("Delete entirely"))
        XCTAssertTrue(instructions.contains("unrecorded — write this down"))
    }
}
