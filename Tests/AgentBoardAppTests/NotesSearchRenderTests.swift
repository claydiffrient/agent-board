import AppKit
import GRDB
import SwiftUI
import XCTest
@testable import AgentBoard
@testable import AgentBoardCore

/// The view wiring under test: query -> `runSearch()` -> `matchIds` -> `visible`
/// (`NotesView.swift:20-23,41-42,122-133`). Identity and order of a match are Core's
/// `NoteStore.search`/`Array.filter` contract, owned by `NoteSearchTests`; this suite only proves the
/// list narrows to the right count for each query, and restores on clear. Row counts come from the
/// AppKit tree (`OffscreenMount.viewCount(ofClassNamed:)`), never the window server, so unlike a pixel
/// diff they can't be thrown off by a first-use rendering cost or an animation tail.
@MainActor
final class NotesSearchRenderTests: XCTestCase {
    private struct Fixture {
        let title: String
        var sections: [(heading: String, body: String)] = []
    }

    private static let watchdog = Fixture(title: "Idle cap watchdog")
    private static let sweep = Fixture(title: "Port sweep", sections: [("Context", "libproc beats lsof")])
    private static let timeout = Fixture(title: "Release checklist", sections: [("Gotchas", "the idle timeout counts sleep")])
    private static let all = [watchdog, sweep, timeout]

    private var mount: OffscreenMount?

    override func tearDown() {
        mount?.close()
        mount = nil
        super.tearDown()
    }

    /// Types every case into one mount in turn, each assertion checked before moving to the next:
    /// "idle" narrows to 2 (a title-only match would give 1, so 2 proves the section-text match too),
    /// "sweep" to 1, clearing restores all 3, the four FTS5-invalid forms still narrow to 2 and raise
    /// no sheet, "cap:" to 1, and the three nothing-searchable forms leave all 3 listed.
    func testAQueryNarrowsTheListToTheMatchingNotes() throws {
        let mount = try makeMount()

        try type("idle", into: mount, expectingRows: 2)
        try type("sweep", into: mount, expectingRows: 1)
        try type("", into: mount, expectingRows: 3)

        for invalid in ["\"idle", "idle -", "(idle", "idl"] {
            try type(invalid, into: mount, expectingRows: 2)
            XCTAssertNil(mount.window.attachedSheet, "\(invalid) raised a sheet")
        }

        try type("cap:", into: mount, expectingRows: 1)

        for nothingSearchable in ["\"", "-", "*"] {
            try type(nothingSearchable, into: mount, expectingRows: 3)
        }
    }

    // MARK: fixtures

    private func makeMount() throws -> OffscreenMount {
        let db = try AppDatabase.inMemory()
        let project = try ProjectStore(db).register(
            name: "notes", repoPath: "/tmp/notes-search-\(UUID().uuidString)", baseBranch: "main",
            worktreeRoot: "/tmp/notes-search-worktrees", memoryDir: nil
        )
        for (offset, fixture) in Self.all.enumerated() {
            let note = try NoteStore(db).create(projectId: project.id, title: fixture.title, sections: fixture.sections)
            try db.writer.write { db in
                try db.execute(
                    sql: "UPDATE note SET updated_at = ? WHERE id = ?",
                    arguments: [1_767_225_600_000 - Int64(offset) * 3_600_000, note.id]
                )
            }
        }
        let mount = OffscreenMount(NotesView(project: project).environment(renderEnvironment(db: db)))
        self.mount = mount
        mount.window.layoutIfNeeded()
        try waitForRows(Self.all.count, in: mount)
        return mount
    }

    private func type(
        _ text: String, into mount: OffscreenMount, expectingRows rows: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let field = try searchField(in: mount)
        field.stringValue = text
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        try waitForRows(rows, in: mount, "\(text.isEmpty ? "(cleared)" : text)", file: file, line: line)
    }

    /// Waits for the row count to settle on `count` and hold for several consecutive polls, so a
    /// transient mid-animation count equal to the target (while the list is still adding or removing
    /// other rows on the way to its real state) can't be mistaken for having arrived.
    private func waitForRows(
        _ count: Int, in mount: OffscreenMount, _ message: String = "",
        agreeing: Int = 5, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let clock = SuspendingClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        var consecutive = 0
        while clock.now < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            mount.window.layoutIfNeeded()
            mount.window.displayIfNeeded()
            if mount.rowCount == count {
                consecutive += 1
                if consecutive >= agreeing { return }
            } else {
                consecutive = 0
            }
        }
        XCTFail("the list never settled on \(count) row(s) for query \(message): has \(mount.rowCount)", file: file, line: line)
    }

    private func searchField(in mount: OffscreenMount) throws -> NSTextField {
        var queue: [NSView] = [mount.host]
        var fields: [NSTextField] = []
        while let view = queue.popLast() {
            if let field = view as? NSTextField, field.isEditable { fields.append(field) }
            queue.append(contentsOf: view.subviews)
        }
        XCTAssertEqual(fields.count, 1, "the screen should hold exactly one editable field, its search")
        return try XCTUnwrap(fields.first)
    }
}

private extension OffscreenMount {
    var rowCount: Int { viewCount(ofClassNamed: "ListTableCellView") }
}
