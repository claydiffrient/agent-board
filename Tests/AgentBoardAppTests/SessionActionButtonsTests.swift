import AgentBoardCore
import XCTest
@testable import AgentBoard

/// The attach and worktree-shell buttons as values: the two symbols, the two titles, the two
/// accessibility labels, and which call site shows a title.
///
/// The symbols are the whole design decision — `bubble.left.fill` against `apple.terminal` — and
/// nothing else in the codebase would fail if one of them drifted back to `terminal`, so they are
/// pinned here rather than left to the renders.
@MainActor
final class SessionActionButtonsTests: XCTestCase {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // AgentBoardAppTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appending(path: relativePath), encoding: .utf8)
    }

    private func session(worktreePath: String?) -> AgentSession {
        AgentSession(
            sessionId: "session-1", shortId: "abcdef12", projectId: "p-1", role: .worker,
            worktreePath: worktreePath, cwd: "/tmp/repo", state: .running
        )
    }

    func testTheTwoButtonsUseTheChosenSymbols() {
        XCTAssertEqual(SessionAction.attach.symbol, "bubble.left.fill")
        XCTAssertEqual(SessionAction.worktreeShell.symbol, "apple.terminal")
        XCTAssertNotEqual(SessionAction.attach.symbol, SessionAction.worktreeShell.symbol)
    }

    /// The button and the window it opens have to show the same glyph, or the shell window looks
    /// like a different feature from the button that opened it.
    func testTheWorktreeButtonMatchesTheReadyWorktreeSymbol() {
        XCTAssertEqual(
            SessionAction.worktreeShell.symbol,
            WorktreeShellAvailability.ready(path: "/tmp/w").symbol
        )
    }

    func testTheTitlesAreAgentAndShell() {
        XCTAssertEqual(SessionAction.attach.title, "Agent")
        XCTAssertEqual(SessionAction.worktreeShell.title, "Shell")
    }

    /// VoiceOver reads these consecutively along the row, so a shared first word would cost the
    /// listener the same hover the sighted user is being spared.
    func testTheAccessibilityLabelsAreDistinctFromTheFirstWord() {
        XCTAssertEqual(SessionAction.attach.accessibilityLabel, "Attach to agent session")
        XCTAssertEqual(SessionAction.worktreeShell.accessibilityLabel, "Open shell in worktree")
        XCTAssertNotEqual(
            SessionAction.attach.accessibilityLabel.split(separator: " ").first,
            SessionAction.worktreeShell.accessibilityLabel.split(separator: " ").first
        )
    }

    func testTheWorktreeHintIsTheDynamicButtonHelp() throws {
        let withWorktree = session(worktreePath: "/tmp/worktrees/w1")
        let without = session(worktreePath: nil)
        XCTAssertEqual(
            WorktreeShellAvailability.buttonHelp(withWorktree), "Open a plain shell in /tmp/worktrees/w1"
        )
        XCTAssertEqual(
            WorktreeShellAvailability.buttonHelp(without),
            "This session has no worktree — it ran in the project's own checkout."
        )
        XCTAssertNotEqual(
            WorktreeShellAvailability.buttonHelp(withWorktree), WorktreeShellAvailability.buttonHelp(without),
            "the help text has to move with the session or it is not dynamic"
        )

        let view = try source("Sources/AgentBoard/Views/Session/SessionActionButtons.swift")
        XCTAssertTrue(view.contains(".accessibilityHint(WorktreeShellAvailability.buttonHelp(session))"))
        XCTAssertTrue(view.contains(".help(WorktreeShellAvailability.buttonHelp(session))"))
        XCTAssertTrue(view.contains(".disabled(!WorktreeShellAvailability.canOpen(session))"))
    }

    func testCanOpenStillGatesTheButton() {
        XCTAssertTrue(WorktreeShellAvailability.canOpen(session(worktreePath: "/tmp/worktrees/w1")))
        XCTAssertFalse(WorktreeShellAvailability.canOpen(session(worktreePath: nil)))
        XCTAssertFalse(WorktreeShellAvailability.canOpen(session(worktreePath: "")))
    }

    /// The two sites differ deliberately: the Actions column truncates a title to `Ag…`, the
    /// inspector row does not. A future edit that unified them would be reverting the decision.
    func testTheTwoCallSitesDisagreeAboutTheTitle() throws {
        XCTAssertTrue(
            try source("Sources/AgentBoard/Views/Status/StatusView.swift")
                .contains("SessionActionButtons(session: session, showsTitle: false)")
        )
        XCTAssertTrue(
            try source("Sources/AgentBoard/Views/TaskBoard/TaskInspectorView.swift")
                .contains("SessionActionButtons(session: session, showsTitle: true)")
        )
    }

    /// Candidate 3's accent bubble and candidate B's prominent capsule were both rejected: the
    /// least consequential control in the row must not be the loudest thing in it.
    func testNeitherButtonCarriesAccentChrome() throws {
        let view = try source("Sources/AgentBoard/Views/Session/SessionActionButtons.swift")
        for banned in ["borderedProminent", "accentColor", ".tint(", "foregroundStyle("] {
            XCTAssertFalse(view.contains(banned), "\(banned) puts colour back on these buttons")
        }
    }

    /// Nothing else should be constructing this pair by hand, or the symbols above stop being the
    /// single address for them.
    func testTheOldTerminalGlyphIsGoneFromBothCallSites() throws {
        for path in [
            "Sources/AgentBoard/Views/Status/StatusView.swift",
            "Sources/AgentBoard/Views/TaskBoard/TaskInspectorView.swift",
        ] {
            let text = try source(path)
            XCTAssertFalse(text.contains("Image(systemName: \"terminal\")"), "\(path) still draws the old glyph")
            XCTAssertFalse(text.contains("openWindow(id: \"worktree-shell\""), "\(path) rebuilt the button by hand")
        }
    }
}
