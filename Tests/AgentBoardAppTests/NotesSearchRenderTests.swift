import AppKit
import GRDB
import SwiftUI
import XCTest
@testable import AgentBoard
@testable import AgentBoardCore

/// Which notes the Notes list shows for a query. The row count comes from the `List`'s cells; which
/// rows they are is proved by pixels, since SwiftUI `Text` leaves no string in the view tree: the
/// searched screen, below its search bar, must draw exactly what a screen holding only the expected
/// notes draws. Each zero is paired with a comparison that must differ.
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

    private var mounts: [OffscreenMount] = []

    override func tearDown() {
        mounts.forEach { $0.close() }
        mounts = []
        super.tearDown()
    }

    func testTwoMountsOfTheSameSearchedListAreIdentical() throws {
        let first = try mount(Self.all, query: "idle", rows: 2)
        let second = try mount(Self.all, query: "idle", rows: 2)
        XCTAssertEqual(first.capture.diff(second.capture, columns: 0..<first.capture.width).count, 0)
    }

    /// "Release checklist" matches only through its section text.
    func testAQueryNarrowsTheListToTheMatchingNotes() throws {
        let searched = try mount(Self.all, query: "idle", rows: 2)
        let onlyTheMatches = try mount([Self.watchdog, Self.timeout], rows: 2)
        XCTAssertEqual(belowSearchBar(searched, onlyTheMatches).count, 0,
                       "the searched list draws something besides the two idle notes, or not in list order")

        let withoutTheSectionMatch = try mount([Self.watchdog], rows: 1)
        XCTAssertGreaterThan(belowSearchBar(searched, withoutTheSectionMatch).count, 0,
                             "a list missing the section match must differ, or the zero above proves nothing")
        XCTAssertGreaterThan(belowSearchBar(try mount(Self.all, rows: 3), onlyTheMatches).count, 0,
                             "without a query Port sweep must be listed, or the zero above proves nothing")
    }

    func testClearingTheQueryRestoresTheWholeList() throws {
        let mounted = try mount(Self.all, rows: 3)
        let unsearched = mounted.capture
        type("sweep", into: mounted.mount)
        let searched = try settledCapture(mounted.mount, rows: 1)
        type("", into: mounted.mount)
        let cleared = try settledCapture(mounted.mount, rows: 3)

        let typed = Mounted(mount: mounted.mount, capture: searched, searchBarBottom: mounted.searchBarBottom)
        XCTAssertEqual(belowSearchBar(typed, try mount([Self.sweep], rows: 1)).count, 0)
        XCTAssertEqual(unsearched.diff(cleared, columns: 0..<unsearched.width).count, 0,
                       "clearing the query left the list different from before it was typed")
    }

    /// Each of these is an FTS5 syntax error typed as-is. None may throw, raise an alert, or leave
    /// the list empty when a note matches the words in it.
    func testHalfTypedAndInvalidQueriesStillListTheMatchingNotes() throws {
        let onlyTheMatches = try mount([Self.watchdog, Self.timeout], rows: 2)
        for typed in ["\"idle", "idle -", "(idle", "idl"] {
            let searched = try mount(Self.all, query: typed, rows: 2)
            XCTAssertEqual(belowSearchBar(searched, onlyTheMatches).count, 0, typed)
            XCTAssertNil(searched.mount.window.attachedSheet, "\(typed) raised a sheet")
        }
        let cap = try mount(Self.all, query: "cap:", rows: 1)
        XCTAssertEqual(belowSearchBar(cap, try mount([Self.watchdog], rows: 1)).count, 0)
    }

    func testAQueryWithNothingSearchableLeavesTheListAlone() throws {
        let whole = try mount(Self.all, rows: 3)
        for typed in ["\"", "-", "*"] {
            XCTAssertEqual(belowSearchBar(try mount(Self.all, query: typed, rows: 3), whole).count, 0, typed)
        }
    }

    // MARK: fixtures

    private struct Mounted {
        let mount: OffscreenMount
        let capture: Capture
        let searchBarBottom: CGFloat
    }

    private func mount(_ notes: [Fixture], query: String = "", rows: Int) throws -> Mounted {
        let db = try AppDatabase.inMemory()
        let project = try ProjectStore(db).register(
            name: "notes", repoPath: "/tmp/notes-search-\(UUID().uuidString)", baseBranch: "main",
            worktreeRoot: "/tmp/notes-search-worktrees", memoryDir: nil
        )
        for (offset, fixture) in Self.all.enumerated() where notes.contains(where: { $0.title == fixture.title }) {
            let note = try NoteStore(db).create(projectId: project.id, title: fixture.title, sections: fixture.sections)
            try db.writer.write { db in
                try db.execute(
                    sql: "UPDATE note SET updated_at = ? WHERE id = ?",
                    arguments: [1_767_225_600_000 - Int64(offset) * 3_600_000, note.id]
                )
            }
        }
        let mount = OffscreenMount(NotesView(project: project).environment(renderEnvironment(db: db)))
        mounts.append(mount)
        mount.window.layoutIfNeeded()
        // Typed before the notes ever arrive, so the List's first real content is already the
        // filtered set: `runSearch` queries the database directly, not `notes.value`, so it finds
        // the right matches even while the list is still empty. Typing only after the unfiltered
        // rows had already settled (the previous order here) made the List remove a row live —
        // an animated transition whose tail a capture can settle on early, mismatching a mount that
        // was never animated at all. Filtering from the first paint means every mount in this file
        // only ever inserts rows, never removes one, so there is no transition left to race.
        if !query.isEmpty { type(query, into: mount) }
        try waitForRows(rows, in: mount)
        let field = try searchField(in: mount)
        let frame = field.convert(field.bounds, to: nil)
        return Mounted(
            mount: mount, capture: try settledCapture(mount, rows: rows),
            searchBarBottom: mount.window.frame.height - frame.minY + 12
        )
    }

    /// `OffscreenMount.capture` forces exactly one fresh window-server surface (`demandAFreshSurface`,
    /// a resize) before polling for pixel stability, then trusts whatever it settles on. That one
    /// refresh is measured elsewhere in this suite to reliably show the window's state at the moment
    /// it fires — but nothing calls it again afterward, so a capture that locks onto a stale-but-
    /// self-consistent surface (the window server simply never recomposited again) reads as settled
    /// pixel-for-pixel while never matching what `rowCount` already confirms the real AppKit tree
    /// shows. A second, independent `capture()` call forces its own fresh resize at a strictly later
    /// moment; requiring it to agree with the first catches that gap without touching the shared
    /// helper every other render-test file also depends on.
    private func settledCapture(_ mount: OffscreenMount, rows: Int) throws -> Capture {
        var last = try mount.capture { _ in mount.rowCount == rows }
        for _ in 0..<3 {
            let next = try mount.capture { _ in mount.rowCount == rows }
            if last.diff(next, columns: 0..<last.width).count == 0 { return next }
            last = next
        }
        XCTFail("two independent captures of the same settled list never agreed")
        return last
    }

    private func waitForRows(_ count: Int, in mount: OffscreenMount) throws {
        let clock = SuspendingClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while clock.now < deadline, mount.rowCount != count {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(mount.rowCount, count, "the list never drew its notes")
    }

    private func type(_ text: String, into mount: OffscreenMount) {
        guard let field = try? searchField(in: mount) else { return XCTFail("no search field mounted") }
        field.stringValue = text
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
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

    private func belowSearchBar(_ left: Mounted, _ right: Mounted) -> PixelDiff {
        let top = max(left.searchBarBottom, right.searchBarBottom)
        return left.capture.diff(right.capture, columns: 0..<left.capture.width, rows: left.capture.rows(below: top))
    }
}

private extension OffscreenMount {
    var rowCount: Int { viewCount(ofClassNamed: "ListTableCellView") }
}
