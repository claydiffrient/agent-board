import AppKit
import SwiftTerm

/// The view behind every terminal surface; Cmd+K clears whichever one is first responder (SPEC §10, Terminal).
class BoardTerminalView: LocalProcessTerminalView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
              event.charactersIgnoringModifiers?.lowercased() == "k",
              window?.firstResponder === self
        else { return super.performKeyEquivalent(with: event) }
        clearScreenAndScrollback()
        return true
    }

    /// SwiftTerm's `mouseDown` never takes focus, and returns early while the child has mouse reporting on (SPEC §10, Terminal).
    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        super.mouseDown(with: event)
    }

    /// Writes the form feed straight to the process, not through `send(source:data:)`, because it is
    /// not keystrokes a subclass should account for as typing.
    func clearScreenAndScrollback() {
        clearScrollback()
        feed(text: "\u{1b}[2J\u{1b}[H")
        process.send(data: [0x0c])
    }
}
