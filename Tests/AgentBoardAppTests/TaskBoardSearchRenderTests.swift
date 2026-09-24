import AppKit
import SwiftUI
import XCTest
@testable import AgentBoard
@testable import AgentBoardCore

/// Which cards the Task Board draws for a query, proved by pixels: a card is not an AppKit view of
/// its own, and SwiftUI `Text` leaves no string in the view tree.
///
/// Each assertion compares a searched board with a second board that holds only the cards the query
/// should leave, below the search bar (whose summary text legitimately differs). Zero differing
/// pixels means the searched board draws exactly that board: the same cards, in the same columns and
/// lanes, and nothing else. Each is paired with a comparison that must differ, so a board that drew
/// nothing at all could not pass.
@MainActor
final class TaskBoardSearchRenderTests: XCTestCase {
    private struct Card {
        let title: String
        let column: TaskColumn
        var epicId: String?
        var archivedAt: Int64?
    }

    private static let idleEpic = "epic-idle-0000"
    private static let portsEpic = "epic-ports-000"

    private var mounts: [OffscreenMount] = []

    override func tearDown() {
        mounts.forEach { $0.close() }
        mounts = []
        super.tearDown()
    }

    func testTwoMountsOfTheSameSearchedBoardAreIdentical() throws {
        let cards = [Card(title: "Idle cap watchdog", column: .running), Card(title: "Port sweep", column: .ready)]
        let first = try mount(cards, query: "idle")
        let second = try mount(cards, query: "idle")
        XCTAssertEqual(first.capture.diff(second.capture, columns: 0..<first.capture.width).count, 0)
    }

    func testAQueryNarrowsTheBoardToTheMatchingTask() throws {
        let board = [
            Card(title: "Idle cap watchdog", column: .running),
            Card(title: "Port sweep", column: .ready),
            Card(title: "Release notes copy", column: .backlog),
        ]
        let onlyTheMatch = [Card(title: "Idle cap watchdog", column: .running)]

        let searched = try mount(board, query: "idle")
        XCTAssertEqual(belowSearchBar(searched, try mount(onlyTheMatch)).count, 0,
                       "the searched board still draws something besides the matching card")

        XCTAssertGreaterThan(belowSearchBar(try mount(board), try mount(onlyTheMatch)).count, 0,
                             "without a query the other two cards must be visible, or the zero above proves nothing")
    }

    func testMatchingTasksStayInTheirOwnColumns() throws {
        let board = [
            Card(title: "Idle cap watchdog", column: .running),
            Card(title: "Idle sweep", column: .backlog),
            Card(title: "Port sweep", column: .ready),
        ]
        let searched = try mount(board, query: "idle")

        let inPlace = [Card(title: "Idle cap watchdog", column: .running), Card(title: "Idle sweep", column: .backlog)]
        XCTAssertEqual(belowSearchBar(searched, try mount(inPlace)).count, 0)

        let swapped = [Card(title: "Idle cap watchdog", column: .backlog), Card(title: "Idle sweep", column: .running)]
        XCTAssertGreaterThan(belowSearchBar(searched, try mount(swapped)).count, 0,
                             "a card in the other column must draw differently, or the zero above proves nothing")
    }

    func testClearingTheQueryRestoresEveryCard() throws {
        let board = [
            Card(title: "Idle cap watchdog", column: .running),
            Card(title: "Port sweep", column: .ready),
            Card(title: "Release notes copy", column: .backlog),
        ]
        let mounted = try mount(board)
        let unsearched = mounted.capture
        type("idle", into: mounted.mount)
        let searched = try mounted.mount.capture()
        type("", into: mounted.mount)
        let cleared = try mounted.mount.capture()

        let onlyTheMatch = try mount([Card(title: "Idle cap watchdog", column: .running)])
        let typed = Mounted(mount: mounted.mount, capture: searched, searchBarBottom: mounted.searchBarBottom)
        XCTAssertEqual(belowSearchBar(typed, onlyTheMatch).count, 0,
                       "typing must have removed the other cards, or the restore below proves nothing")
        XCTAssertEqual(unsearched.diff(cleared, columns: 0..<unsearched.width).count, 0,
                       "clearing the query left the board different from before it was typed")
    }

    func testAnEpicLaneWithNothingMatchingVanishesHeaderAndAll() throws {
        let board = [
            Card(title: "Idle cap watchdog", column: .running, epicId: Self.idleEpic),
            Card(title: "Port sweep", column: .ready, epicId: Self.portsEpic),
        ]
        let withoutPorts = [Card(title: "Idle cap watchdog", column: .running, epicId: Self.idleEpic)]

        XCTAssertEqual(belowSearchBar(try mount(board, query: "idle"), try mount(withoutPorts, query: "idle")).count, 0,
                       "the Ports lane left a header, a rail entry or a gap behind")
        XCTAssertGreaterThan(belowSearchBar(try mount(board), try mount(withoutPorts)).count, 0,
                             "without a query the Ports lane must be visible, or the zero above proves nothing")
    }

    /// Search does not reach past Show Archived, but a lane hiding an archived match survives the
    /// query so its cell can say where the match is.
    func testAnArchivedMatchStaysHiddenButKeepsItsLaneAndNotice() throws {
        let archived = Card(title: "Idle cap watchdog", column: .done, archivedAt: 5_000)
        let searched = try mount([archived, Card(title: "Port sweep", column: .ready)], query: "idle")

        XCTAssertEqual(belowSearchBar(searched, try mount([archived], query: "idle")).count, 0)
        XCTAssertGreaterThan(belowSearchBar(searched, try mount([], query: "idle")).count, 0,
                             "a board with no match at all must differ, or the lane and its notice are not drawn")
    }

    // MARK: fixtures

    private struct Mounted {
        let mount: OffscreenMount
        let capture: Capture
        /// The search field's bottom edge in points from the window's top, plus a margin that clears
        /// the summary text and the clear control on the same row.
        let searchBarBottom: CGFloat
    }

    private func mount(_ cards: [Card], query: String = "") throws -> Mounted {
        let db = try AppDatabase.inMemory()
        let project = try ProjectStore(db).register(
            name: "search", repoPath: "/tmp/board-search-\(UUID().uuidString)", baseBranch: "main",
            worktreeRoot: "/tmp/board-search-worktrees", memoryDir: nil
        )
        let epics = [(Self.idleEpic, "Idle cap"), (Self.portsEpic, "Ports")]
        for (index, (id, title)) in epics.enumerated() where cards.contains(where: { $0.epicId == id }) {
            try db.writer.write { db in
                try Epic(
                    id: id, projectId: project.id, title: title, goal: nil, branch: "agentboard/\(id)",
                    state: .active, createdAt: Int64(1_000 - index)
                ).insert(db)
            }
        }
        for card in cards {
            let task = try TaskStore(db).create(
                projectId: project.id, title: card.title, body: nil, acceptance: nil, priority: nil,
                column: card.column, origin: .human, epicId: card.epicId
            )
            if card.archivedAt != nil { try TaskStore(db).archive(ids: [task.id]) }
        }
        let mount = OffscreenMount(
            TaskBoardView(project: project).environment(renderEnvironment(db: db)),
            size: CGSize(width: 1900, height: 540)
        )
        mounts.append(mount)
        mount.window.layoutIfNeeded()
        if !query.isEmpty { type(query, into: mount) }
        let field = try searchField(in: mount)
        let frame = field.convert(field.bounds, to: nil)
        return Mounted(
            mount: mount, capture: try mount.capture(),
            searchBarBottom: mount.window.frame.height - frame.minY + 12
        )
    }

    /// What typing does to a SwiftUI `TextField`: its coordinator reads `stringValue` when the
    /// control reports a text change.
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
        XCTAssertEqual(fields.count, 1, "the board should hold exactly one editable field, its search")
        return try XCTUnwrap(fields.first)
    }

    private func belowSearchBar(_ left: Mounted, _ right: Mounted) -> PixelDiff {
        let top = max(left.searchBarBottom, right.searchBarBottom)
        return left.capture.diff(right.capture, columns: 0..<left.capture.width, rows: left.capture.rows(below: top))
    }
}
