import AgentBoardCore
import AppKit
import SwiftUI
import XCTest
@testable import AgentBoard

/// The copy button in a note section's header (SPEC §10, Notes).
///
/// The pasteboard assertions run against a privately named `NSPasteboard` so a test run never
/// touches the clipboard of whoever is at the machine.
@MainActor
final class NoteSectionCopyTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("com.agentboard.tests.\(UUID().uuidString)"))
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        pasteboard = nil
        super.tearDown()
    }

    func testTheCopiedTextCarriesTheHeadingAsAMarkdownHeading() {
        XCTAssertEqual(
            NoteSectionClipboard.markdown(heading: "The trap", body: "A worker survives the board."),
            "## The trap\n\nA worker survives the board."
        )
    }

    func testSurroundingBlankLinesAreTrimmedSoTwoCopiesPasteIdentically() {
        XCTAssertEqual(
            NoteSectionClipboard.markdown(heading: "  The trap  ", body: "\n\nbody text\n\n\n"),
            "## The trap\n\nbody text"
        )
    }

    func testAnEmptySectionCopiesItsHeadingAlone() {
        XCTAssertEqual(NoteSectionClipboard.markdown(heading: "Evidence", body: "   \n"), "## Evidence")
    }

    func testCopyingPutsTheSectionOnThePasteboardAndReplacesWhatWasThere() {
        pasteboard.clearContents()
        pasteboard.setString("stale", forType: .string)

        NoteSectionClipboard.copy(heading: "Evidence", body: "libproc beats lsof by 15x.", to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "## Evidence\n\nlibproc beats lsof by 15x.")
    }

    /// The section header gained a button; this is the evidence available on a machine with no
    /// display that the editor still draws. No string on this screen is readable headless — see
    /// the project's "Headless UI verification" note — so the button itself is not asserted on.
    func testTheEditorStillRendersWithTheCopyButtonInEverySectionHeader() throws {
        let (db, project, note) = try fixture(
            sections: [("The trap", "saved body"), ("Evidence", "measured")]
        )
        let mount = OffscreenMount(
            NoteEditorView(project: project, noteId: note.id, onDelete: {})
                .environment(renderEnvironment(db: db)),
            size: CGSize(width: 700, height: 900)
        )
        defer { mount.close() }

        let capture = try mount.capture()

        XCTAssertFalse(capture.isBlank, "the note editor drew nothing")
    }

    func testCopyingASectionLeavesTheStoredNoteUntouched() throws {
        let (db, _, note) = try fixture(sections: [("The trap", "saved body")])

        NoteSectionClipboard.copy(heading: "The trap", body: "saved body plus an unsaved line", to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "## The trap\n\nsaved body plus an unsaved line")
        XCTAssertEqual(try NoteStore(db).detail(noteId: note.id)?.sections.first?.body, "saved body")
        XCTAssertEqual(try NoteStore(db).detail(noteId: note.id)?.note.version, note.version)
    }

    // MARK: Fixtures

    private func fixture(sections: [(heading: String, body: String)]) throws -> (AppDatabase, Project, Note) {
        let db = try AppDatabase.inMemory()
        let project = try ProjectStore(db).register(
            name: "Copy", repoPath: "/tmp/note-copy-\(UUID().uuidString)", baseBranch: "main",
            worktreeRoot: "/tmp/note-copy-worktrees", memoryDir: nil
        )
        let note = try NoteStore(db).create(projectId: project.id, title: "Finding", sections: sections)
        return (db, project, note)
    }
}
