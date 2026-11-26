import AppKit
import XCTest
@testable import AgentBoard

@MainActor
final class TerminalClickFocusTests: XCTestCase {
    func testAClickInTheTerminalTakesFocusBackWhileTheChildReportsMouseEvents() throws {
        let terminal = BoardTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        terminal.feed(text: "\u{1b}[?1000h")
        let field = NSTextField(frame: NSRect(x: 620, y: 0, width: 160, height: 24))
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(terminal)
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertFalse(window.firstResponder === terminal)

        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 300, y: 300), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        terminal.mouseDown(with: click)

        XCTAssertTrue(window.firstResponder === terminal, "first responder is \(String(describing: window.firstResponder))")
    }
}
