import AppKit
import SwiftTerm
import XCTest
@testable import AgentBoard

@MainActor
final class TerminalClearShortcutTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("TerminalClearShortcutTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func mount(_ views: NSView...) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        for view in views { window.contentView?.addSubview(view) }
        return window
    }

    private func commandK(in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40
        )!
    }

    private func fill(_ terminal: BoardTerminalView) {
        terminal.feed(text: (1...200).map { "line \($0)" }.joined(separator: "\r\n"))
    }

    private func text(of terminal: BoardTerminalView) -> String {
        String(decoding: terminal.getTerminal().getBufferAsData(), as: UTF8.self)
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await _Concurrency.Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    func testCommandKEmptiesTheFocusedTerminalAndSendsTheChildAFormFeed() async throws {
        let ready = directory.appendingPathComponent("ready")
        let received = directory.appendingPathComponent("received")
        let terminal = BoardTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let window = mount(terminal)
        XCTAssertTrue(window.makeFirstResponder(terminal))
        terminal.startProcess(
            executable: "/bin/sh",
            args: ["-c", "stty raw -echo; : > \"$1\"; exec dd bs=1 count=1 of=\"$2\" 2>/dev/null", "sh", ready.path, received.path]
        )
        defer { terminal.terminate() }
        let started = await waitUntil { FileManager.default.fileExists(atPath: ready.path) }
        XCTAssertTrue(started, "the child never put its terminal in raw mode")
        fill(terminal)
        XCTAssertTrue(text(of: terminal).contains("line 1\n"), "the first line should be in scrollback before the clear")
        let scroller = try XCTUnwrap(terminal.subviews.lazy.compactMap { $0 as? NSScroller }.first)
        XCTAssertLessThan(scroller.knobProportion, 1)

        XCTAssertTrue(terminal.performKeyEquivalent(with: commandK(in: window)))

        let remaining = text(of: terminal)
        XCTAssertEqual(remaining.trimmingCharacters(in: .whitespacesAndNewlines), "")
        XCTAssertEqual(remaining.filter { $0 == "\n" }.count, terminal.getTerminal().rows, "scrollback survived the clear")
        XCTAssertEqual(scroller.knobProportion, 1, "the scroller still sized its knob for the old scrollback")
        let delivered = await waitUntil { (try? Data(contentsOf: received)) == Data([0x0c]) }
        XCTAssertTrue(delivered, "the child read \(String(describing: try? Data(contentsOf: received))) instead of a form feed")
    }

    func testCommandKIsNotConsumedWhenTheTerminalIsNotFocused() {
        let terminal = BoardTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let field = NSTextField(frame: NSRect(x: 0, y: 650, width: 200, height: 24))
        let window = mount(terminal, field)
        XCTAssertTrue(window.makeFirstResponder(field))
        fill(terminal)

        XCTAssertFalse(terminal.performKeyEquivalent(with: commandK(in: window)))
        XCTAssertTrue(text(of: terminal).contains("line 200"))
    }
}
