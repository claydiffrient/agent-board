import AppKit

/// What the section header's copy button puts on the pasteboard. The heading travels as a
/// markdown H2 so a pasted section still says what it is, and the body is copied as it stands
/// in the editor — unsaved edits included.
enum NoteSectionClipboard {
    static func markdown(heading: String, body: String) -> String {
        let heading = heading.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = heading.isEmpty ? "" : "## \(heading)"
        if title.isEmpty { return body }
        return body.isEmpty ? title : "\(title)\n\n\(body)"
    }

    @discardableResult
    static func copy(heading: String, body: String, to pasteboard: NSPasteboard = .general) -> String {
        let text = markdown(heading: heading, body: body)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return text
    }
}
