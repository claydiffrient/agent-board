import AppKit
import XCTest
@testable import AgentBoard

/// The PTY has no child here, so `LocalProcess.send` drops the bytes; what is under test is the
/// dirty bookkeeping the view keeps on the way past.
@MainActor
final class OrchestratorTerminalViewTests: XCTestCase {
    private func makeView() -> (OrchestratorTerminalView, () -> Int) {
        let view = OrchestratorTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        var clears = 0
        view.promptDidClear = { clears += 1 }
        return (view, { clears })
    }

    private func type(_ view: OrchestratorTerminalView, _ text: String) {
        view.send(source: view, data: Array(text.utf8)[...])
    }

    func testTypingDirtiesThePrompt() {
        let (view, _) = makeView()
        type(view, "half a thought")
        XCTAssertTrue(view.promptIsDirty)
    }

    func testSubmittingClearsThePromptAndFiresTheCallback() {
        let (view, clears) = makeView()
        type(view, "half a thought")
        type(view, "\r")
        XCTAssertFalse(view.promptIsDirty)
        XCTAssertEqual(clears(), 1)
    }

    func testControlCClearsThePrompt() {
        let (view, clears) = makeView()
        type(view, "half a thought")
        view.send(source: view, data: [0x03][...])
        XCTAssertFalse(view.promptIsDirty)
        XCTAssertEqual(clears(), 1)
    }

    func testAnArrowKeyLeavesThePromptDirty() {
        let (view, clears) = makeView()
        type(view, "half a thought")
        view.send(source: view, data: [0x1b, 0x5b, 0x44][...])
        XCTAssertTrue(view.promptIsDirty)
        XCTAssertEqual(clears(), 0)
    }

    func testTheConsolesOwnInjectionDoesNotTouchTheDirtyFlag() {
        let (view, clears) = makeView()
        type(view, "half a thought")

        view.isInjecting = true
        type(view, "[agent-board] 2 worker reports pending. Call list_reports.\r")
        view.isInjecting = false

        XCTAssertTrue(view.promptIsDirty, "an injection cleared the flag that protects the human's text")
        XCTAssertEqual(clears(), 0)
    }
}
