import AgentBoardCore
import AppKit
import SwiftUI
import XCTest
@testable import AgentBoard

/// The attention badge on a single sidebar row, rasterized on its own.
///
/// What this proves: a project that needs a human draws differently from one that does not, at the
/// 220-point ideal sidebar width and still at the 180-point minimum a viewer can drag it down to.
///
/// What it cannot prove: that the dot is the right size or colour, or that it sits far enough from
/// the gear to read as separate. Nobody has looked at these pixels — they have only been compared.
@MainActor
final class ProjectRowBadgeRenderTests: XCTestCase {
    private func project(_ name: String) -> Project {
        Project(
            id: "p-\(name)", name: name, repoPath: "/tmp/\(name)", baseBranch: "main",
            worktreeRoot: "/tmp/\(name)-worktrees", memoryDir: nil, orchSessionId: nil,
            settingsJSON: "{}", createdAt: 0
        )
    }

    private func pixels(_ project: Project, _ attention: ProjectAttention?, width: CGFloat) throws -> Data {
        let hosting = NSHostingView(
            rootView: ProjectRow(project: project, attention: attention, openSettings: {})
                .frame(width: width, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
        )
        hosting.layoutSubtreeIfNeeded()
        hosting.frame = NSRect(
            origin: .zero, size: CGSize(width: width, height: max(hosting.fittingSize.height, 1))
        )
        hosting.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    func testABadgedRowDoesNotRenderLikeAQuietOne() throws {
        let alpha = project("Alpha")
        let waiting = ProjectAttention(
            id: alpha.id, name: alpha.name,
            causes: [AttentionCause(reason: .pendingApproval, count: 1)]
        )
        XCTAssertNotEqual(
            try pixels(alpha, waiting, width: 220), try pixels(alpha, nil, width: 220),
            "a project needing attention must not draw the same as one that does not"
        )
    }

    /// The sidebar can be dragged down to `navigationSplitViewColumnWidth(min: 180, …)`. The badge
    /// has to survive that squeeze, not just the 220-point ideal, and a long name is what squeezes.
    func testTheBadgeStaysVisibleAtTheMinimumSidebarWidth() throws {
        let long = Project(
            id: "p-long", name: "a-project-with-a-name-long-enough-to-truncate", repoPath: "/tmp/long",
            baseBranch: "main", worktreeRoot: "/tmp/long-worktrees", memoryDir: nil,
            orchSessionId: nil, settingsJSON: "{}", createdAt: 0
        )
        let waiting = ProjectAttention(
            id: long.id, name: long.name,
            causes: [AttentionCause(reason: .blockedWorker, count: 1, detail: "Wire the thing")]
        )
        XCTAssertNotEqual(
            try pixels(long, waiting, width: 180), try pixels(long, nil, width: 180),
            "a long name must not squeeze the badge out at the 180-point minimum"
        )
    }
}

/// What a collapsed section's badge says. The tooltip strings are pure values, so they are checked
/// as values; `.help()` does not reach `NSView.toolTip`, so the fact that the badge *carries* them
/// is verified by reading `AttentionBadge`, not by a test.
final class CollapsedSectionSummaryTests: XCTestCase {
    private func project(_ name: String) -> Project {
        Project(
            id: "p-\(name)", name: name, repoPath: "/tmp/\(name)", baseBranch: "main",
            worktreeRoot: "/tmp/\(name)-worktrees", memoryDir: nil, orchSessionId: nil,
            settingsJSON: "{}", createdAt: 0
        )
    }

    private var alpha: Workspace { Workspace(id: "w1", name: "Alpha", ordering: 0, createdAt: 0) }

    func testItNamesEveryWaitingProjectHiddenInside() {
        let section = ProjectSection(
            workspace: alpha, projects: [project("one"), project("two"), project("three")]
        )
        let attention = [
            "p-one": ProjectAttention(
                id: "p-one", name: "one", causes: [AttentionCause(reason: .pendingApproval, count: 1)]
            ),
            "p-three": ProjectAttention(
                id: "p-three", name: "three",
                causes: [AttentionCause(reason: .overdueShutdown, count: 2)]
            ),
        ]
        XCTAssertEqual(
            collapsedSectionSummary(section, attention: attention),
            """
            one: 1 approval waiting.
            three: 2 agents have not acknowledged shutdown.
            """
        )
    }

    func testAQuietSectionHasNothingToSay() {
        let section = ProjectSection(workspace: alpha, projects: [project("one")])
        XCTAssertNil(collapsedSectionSummary(section, attention: [:]))
        XCTAssertNil(
            collapsedSectionSummary(
                section,
                attention: ["p-one": ProjectAttention(id: "p-one", name: "one", causes: [])]
            )
        )
    }
}

/// The badge in the real sidebar, against a real database.
///
/// The whole `MainWindow` is mounted in an offscreen borderless window and captured with
/// `CGWindowListCreateImage`, which is the one route that rasterizes a SwiftUI `List` on a machine
/// with no display — `cacheDisplay` and `ImageRenderer` both come back blank for list content.
/// `OffscreenMount` holds the window across mutations and captures only once the picture has
/// stopped moving; `renderEnvironment` keeps the sidebar footer from drawing, because it reads the
/// real `~/.claude.json` on a background task and would otherwise appear mid-capture.
///
/// What these prove: two mounts of the same quiet board are pixel-identical, so any difference is
/// the change under test and not animation; a pending approval adds a mark a dozen points wide
/// inside the sidebar; resolving it restores the original pixels exactly; and a project inside a
/// collapsed section marks its header even though its own row is never drawn.
///
/// What they cannot prove: what the mark looks like, or that its tooltip appears on hover. There is
/// nobody to hover, and SwiftUI's `.help()` leaves no readable string in the AppKit or
/// accessibility trees (measured: every `toolTip` is nil and `accessibilityChildren()` is empty).
@MainActor
final class SidebarAttentionLiveTests: XCTestCase {
    private var collapse = IsolatedCollapseState()

    override func setUp() {
        super.setUp()
        collapse = IsolatedCollapseState()
    }

    override func tearDown() {
        collapse.remove()
        super.tearDown()
    }

    /// The sidebar at its 220-point ideal, doubled by the backing scale of the capture.
    private static let sidebar = 0..<460

    private func mount(_ db: AppDatabase) -> OffscreenMount {
        OffscreenMount(MainWindow(collapseState: collapse.state).environment(renderEnvironment(db: db)))
    }

    private func diff(_ a: Capture, _ b: Capture) -> PixelDiff {
        a.diff(b, columns: Self.sidebar)
    }

    private func register(_ db: AppDatabase, _ name: String) throws -> Project {
        try ProjectStore(db).register(
            name: name, repoPath: "/tmp/badge-\(UUID().uuidString)", baseBranch: "main",
            worktreeRoot: "/tmp/badge-worktrees", memoryDir: nil
        )
    }

    /// The control every other assertion here rests on: nothing in this window moves on its own,
    /// so a pixel difference means the board changed.
    func testTwoMountsOfTheSameQuietBoardAreIdentical() throws {
        let db = try AppDatabase.inMemory()
        _ = try register(db, "Alpha")
        collapse.state.save([])

        let first = mount(db)
        let second = mount(db)
        defer { first.close(); second.close() }
        XCTAssertEqual(
            diff(try first.capture(columns: Self.sidebar), try second.capture(columns: Self.sidebar)).count, 0,
            "the sidebar must render deterministically"
        )
    }

    func testTheBadgeAppearsWhenTheConditionAppearsAndClearsWhenItClears() throws {
        let db = try AppDatabase.inMemory()
        let alpha = try register(db, "Alpha")
        _ = try register(db, "Beta")
        collapse.state.save([])

        let board = mount(db)
        defer { board.close() }
        let quiet = try board.capture(columns: Self.sidebar)

        let approval = try ApprovalStore(db).create(
            projectId: alpha.id, kind: .spawn, taskId: nil, epicId: nil,
            requestedBy: "orchestrator", reason: "spawn a worker"
        )
        let badged = try board.capture(columns: Self.sidebar) { self.diff(quiet, $0).count > 0 }
        let appeared = diff(quiet, badged)
        XCTAssertGreaterThan(appeared.count, 0, "the pending approval must show in the sidebar")
        XCTAssertLessThan(
            appeared.width, 40,
            "a dot, not a relayout: the badge must not shift the name or the gear (\(appeared.width)pt wide)"
        )
        XCTAssertLessThan(appeared.height, 40, "the badge must stay inside its own row")
        XCTAssertGreaterThan(
            appeared.minX, Self.sidebar.upperBound / 2,
            "the badge belongs on the trailing side of the row, beside the gear"
        )

        try ApprovalStore(db).resolve(approval.id, .denied)
        let restored = try board.capture(columns: Self.sidebar) { self.diff(quiet, $0).count == 0 }
        XCTAssertEqual(
            diff(quiet, restored).count, 0,
            "resolving the approval must restore the quiet sidebar exactly"
        )
    }

    /// The case the feature exists for: the project needing a human is inside a section the viewer
    /// has collapsed, so its own row is never drawn.
    func testACollapsedSectionShowsTheAttentionOfTheRowsItHides() throws {
        func board(withApproval: Bool) throws -> (AppDatabase, String) {
            let db = try AppDatabase.inMemory()
            let workspaces = WorkspaceStore(db)
            let alpha = try workspaces.create(name: "Alpha")
            let hidden = try register(db, "Hidden")
            try workspaces.assign(projectId: hidden.id, workspaceId: alpha.id)
            if withApproval {
                _ = try ApprovalStore(db).create(
                    projectId: hidden.id, kind: .spawn, taskId: nil, epicId: nil,
                    requestedBy: "orchestrator", reason: nil
                )
            }
            return (db, alpha.id)
        }

        let (quietDb, workspaceId) = try board(withApproval: false)
        // Read when `MainWindow`'s state initializes, so it has to be in place before the mount.
        collapse.state.save([workspaceId])
        let quietMount = mount(quietDb)
        defer { quietMount.close() }
        let quiet = try quietMount.capture(columns: Self.sidebar)
        XCTAssertEqual(
            quietMount.viewCount(ofClassNamed: "ListTableCellView"), 1,
            "only the pinned At a Glance row may be drawn"
        )

        let (waitingDb, waitingWorkspaceId) = try board(withApproval: true)
        collapse.state.save([waitingWorkspaceId])
        let waitingMount = mount(waitingDb)
        defer { waitingMount.close() }
        let waiting = try waitingMount.capture(columns: Self.sidebar)
        XCTAssertEqual(
            waitingMount.viewCount(ofClassNamed: "ListTableCellView"), 1,
            "the waiting project's own row is still hidden"
        )

        let marked = diff(quiet, waiting)
        XCTAssertGreaterThan(marked.count, 0, "a collapsed section must still say something is inside")
        XCTAssertLessThan(marked.width, 40, "the header badge is a dot, not a relayout")
    }

    /// While the rows are visible they carry their own badges, so the header must not repeat it.
    func testAnExpandedSectionLeavesItsHeaderAlone() throws {
        let db = try AppDatabase.inMemory()
        let workspaces = WorkspaceStore(db)
        let alpha = try workspaces.create(name: "Alpha")
        let shown = try register(db, "Shown")
        try workspaces.assign(projectId: shown.id, workspaceId: alpha.id)
        collapse.state.save([])

        let board = mount(db)
        defer { board.close() }
        let quiet = try board.capture(columns: Self.sidebar)
        _ = try ApprovalStore(db).create(
            projectId: shown.id, kind: .spawn, taskId: nil, epicId: nil,
            requestedBy: "orchestrator", reason: nil
        )
        let badged = diff(quiet, try board.capture(columns: Self.sidebar) { self.diff(quiet, $0).count > 0 })
        XCTAssertGreaterThan(badged.count, 0)
        XCTAssertLessThan(
            badged.height, 40,
            "one badge on the row; a second on the header would make the difference two rows tall"
        )
    }
}
