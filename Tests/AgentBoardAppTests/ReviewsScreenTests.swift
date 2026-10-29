import AgentBoardCore
import AgentBoardRuntime
import AppKit
import SwiftUI
import XCTest
@testable import AgentBoard

/// SPEC §10 Reviews and §13.7: the Reviews row and page over a fake CDR.
///
/// What the mounts prove: which sections and how many rows the page lists, the daemon toggle's state and
/// whether it is enabled (a SwiftUI `Toggle` mounts as an `NSSwitch`), that the page polls only while
/// mounted, and that the sidebar row follows whether CDR is installed. What they cannot prove: any of
/// the text. Section titles, row details and the status line are SwiftUI `Text`, unreadable offscreen.
@MainActor
final class ReviewsScreenTests: XCTestCase {
    private var collapse = IsolatedCollapseState()

    override func setUp() {
        super.setUp()
        collapse = IsolatedCollapseState()
    }

    override func tearDown() {
        collapse.remove()
        super.tearDown()
    }

    func testTheRunningDaemonListsItsRunningAndQueuedReviewsWithTheToggleOn() throws {
        let cdr = FakeCDR(daemon: .running(try Self.status()), reviews: try Self.reviews())
        let page = try mountPage(cdr)

        // Running, Queued, Waiting out the delay, Parked, Recent reviews; Retrying is empty and hidden.
        XCTAssertEqual(page.headers, 5)
        // One row per entry: 1 running, 1 queued, 1 waiting, 1 parked, 3 recent reviews.
        XCTAssertEqual(page.cells, 7)
        XCTAssertEqual(page.switches.map(\.state), [.on])
        XCTAssertEqual(page.switches.map(\.isEnabled), [true])
    }

    func testTheStoppedDaemonStillListsRecentReviewsWithTheToggleOff() throws {
        let cdr = FakeCDR(daemon: .stopped, reviews: try Self.reviews())
        let page = try mountPage(cdr)

        XCTAssertEqual(page.headers, 2, "Running and Recent reviews")
        XCTAssertEqual(page.cells, 1 + 3, "Running's placeholder and the three recent reviews")
        XCTAssertEqual(page.switches.map(\.state), [.off])
        XCTAssertEqual(page.switches.map(\.isEnabled), [true])
    }

    func testEscalationsListUnderWaitingOnYouAndAnUnreadableListStillShowsTheSection() throws {
        let escalation = try JSONDecoder().decode(CDREscalation.self, from: Data("""
            {"target_id": 12, "repo": "octo/widgets", "pr": 401, "title": "Cache the avatar sizes",
             "finding": "The cache key ignores the device scale", "argued": "Scale is already folded in.",
             "argued_verdict": "uncertain", "posted_at": "2026-10-28 16:02:11",
             "reply_url": null, "thread_url": "https://github.com/octo/widgets/pull/401#discussion_r9001"}
            """.utf8))
        let waiting = try mountPage(FakeCDR(daemon: .stopped, reviews: try Self.reviews(), escalations: .available([escalation])))
        XCTAssertEqual(waiting.headers, 3, "Waiting on you, Running and Recent reviews")
        XCTAssertEqual(waiting.cells, 1 + 1 + 3, "the escalation, Running's placeholder and the three recent reviews")

        let unreadable = try mountPage(FakeCDR(daemon: .stopped, reviews: try Self.reviews(), escalations: .unavailable("database is locked")))
        XCTAssertEqual(unreadable.headers, 3, "an unreadable list is not an empty one")
    }

    func testThePagePollsWhileMountedAndStopsWhenRemoved() throws {
        let cdr = FakeCDR(daemon: .stopped, reviews: .serverNotRunning)
        let mount = OffscreenMount(
            ReviewsView(pollInterval: .milliseconds(50)).environment(renderEnvironment(db: try AppDatabase.inMemory(), cdr: cdr))
        )
        addTeardownBlock { mount.window.orderOut(nil) }
        pump(mount.window) { cdr.snapshotCalls >= 3 }
        XCTAssertGreaterThanOrEqual(cdr.snapshotCalls, 3, "the page must keep reading CDR while it is shown")

        mount.window.contentView = NSView()
        pumpBriefly(mount.window, turns: 10)
        let afterRemoval = cdr.snapshotCalls
        pumpBriefly(mount.window, turns: 25)
        XCTAssertEqual(cdr.snapshotCalls, afterRemoval, "the page kept polling after it was removed")
    }

    func testTheToggleRunsCDRAndShowsItsRefusal() async throws {
        let refusal = "cdr: 1 review is running; restart with --force to cut it short"
        let cdr = FakeCDR(daemon: .running(try Self.status()), reviews: .serverNotRunning)
        cdr.failure = .failed(status: 5, stderr: refusal)
        let model = ReviewsModel()
        await model.resolveCommand(configured: "", cdr: cdr)
        await model.refresh(cdr)
        XCTAssertTrue(model.canToggle)

        await model.setDaemon(running: false, cdr: cdr)

        XCTAssertEqual(cdr.requested, [false])
        XCTAssertEqual(model.commandError, refusal)
        XCTAssertNil(model.pendingRunning)
        XCTAssertTrue(model.toggleIsOn, "a refused stop leaves the daemon, and the toggle, running")
    }

    func testWithNoCDRCommandTheToggleIsDisabled() async throws {
        let cdr = FakeCDR(daemon: .stopped, reviews: .serverNotRunning)
        cdr.command = .failure(.cliNotFound(configured: nil))
        let model = ReviewsModel()
        await model.resolveCommand(configured: "", cdr: cdr)
        await model.refresh(cdr)

        XCTAssertFalse(model.canToggle)
        await model.setDaemon(running: true, cdr: cdr)
        XCTAssertEqual(cdr.requested, [])
    }

    func testTheSidebarPinsReviewsOnlyWhileCDRIsInstalled() throws {
        let installed = FakeCDR(daemon: .stopped, reviews: .serverNotRunning)
        let absent = FakeCDR(daemon: .notInstalled, reviews: .serverNotRunning)
        absent.installed = false

        XCTAssertEqual(try sidebarRows(cdr: installed), SidebarSelection.pinned.count + 1)
        XCTAssertEqual(try sidebarRows(cdr: absent), SidebarSelection.pinned.count)
        XCTAssertEqual(try sidebarRows(cdr: nil), SidebarSelection.pinned.count)
    }

    // MARK: - Mounts

    private struct Page {
        let headers: Int
        let cells: Int
        let switches: [NSSwitch]
    }

    private func mountPage(_ cdr: FakeCDR) throws -> Page {
        let mount = OffscreenMount(
            ReviewsView().environment(renderEnvironment(db: try AppDatabase.inMemory(), cdr: cdr)),
            size: CGSize(width: 900, height: 900)
        )
        addTeardownBlock { mount.window.orderOut(nil) }
        var stableReads = 0
        var last = -1
        pump(mount.window) {
            let cells = mount.viewCount(ofClassNamed: "ListTableCellView")
            stableReads = cells == last && cdr.snapshotCalls > 0 ? stableReads + 1 : 0
            last = cells
            return stableReads >= 5
        }
        return Page(
            headers: mount.viewCount(ofClassNamed: "ListTableHeaderView"),
            cells: mount.viewCount(ofClassNamed: "ListTableCellView"),
            switches: Self.collect(NSSwitch.self, in: mount.host)
        )
    }

    private func sidebarRows(cdr: FakeCDR?) throws -> Int {
        let mount = OffscreenMount(
            MainWindow(collapseState: collapse.state)
                .environment(renderEnvironment(db: try AppDatabase.inMemory(), cdr: cdr))
        )
        addTeardownBlock { mount.window.orderOut(nil) }
        var stableReads = 0
        var last = -1
        pump(mount.window) {
            let cells = mount.viewCount(ofClassNamed: "ListTableCellView")
            stableReads = cells == last && cells > 0 ? stableReads + 1 : 0
            last = cells
            return stableReads >= 5
        }
        return mount.viewCount(ofClassNamed: "ListTableCellView")
    }

    private static func collect<V: NSView>(_ type: V.Type, in root: NSView) -> [V] {
        var found: [V] = []
        var queue = [root]
        while let view = queue.popLast() {
            if let match = view as? V { found.append(match) }
            queue.append(contentsOf: view.subviews)
        }
        return found
    }

    // MARK: - Fixtures

    private static func status() throws -> CDRStatus {
        let entry = { (request: Int, pr: Int) in
            """
            {"request": \(request), "repo": "octo/widgets", "pr": \(pr), "title": "Change \(pr)",
             "url": "https://github.com/octo/widgets/pull/\(pr)", "requestedAt": "2026-10-29T15:20:00.000Z"
            """
        }
        let json = """
            {"pid": 41001, "polling": {
              "running": [\(entry(1, 401)), "startedAt": "2026-10-29T15:25:03.000Z", "progress": {"phase": "reviewing"}}],
              "queued": [\(entry(2, 402)), "dueAt": "2026-10-29T15:35:00.000Z", "blockedBy": "concurrency"}],
              "waiting": [\(entry(3, 403)), "dueAt": "2026-10-29T15:43:00.000Z"}],
              "retrying": [],
              "parked": [\(entry(4, 404)), "attempts": 5, "lastError": "the review timed out"}],
              "paused": false,
              "budget": {"limit": 15, "used": 4, "exhausted": false},
              "concurrency": {"limit": 2, "running": 1},
              "nextPollAt": "2026-10-29T15:41:00.000Z"
            }}
            """
        return try JSONDecoder().decode(CDRStatus.self, from: Data(json.utf8))
    }

    private static func reviews() throws -> CDRReviewsState {
        let json = """
            [
              {"id": 12, "owner": "octo", "repo": "widgets", "pr": 401, "title": "Cache the avatar sizes",
               "reviews": [
                 {"id": 300, "started_at": "2026-10-20 10:00:05", "finished_at": "2026-10-20 10:09:40",
                  "verdict": "changes requested", "source": "manual", "findings": 3},
                 {"id": 311, "started_at": "2026-10-28 09:05:00", "finished_at": "2026-10-28 09:12:30",
                  "verdict": "approve", "source": "cdr", "findings": 0}
               ], "to_post": 2},
              {"id": 15, "owner": "octo", "repo": "gadgets", "pr": 3, "title": "Teach the parser about tabs",
               "reviews": [{"id": 305, "started_at": "2026-10-26 12:00:00", "source": "cdr"}], "to_post": 0}
            ]
            """
        let targets = try JSONDecoder().decode([CDRTarget].self, from: Data(json.utf8))
        return .available(CDRReviewList(baseURL: URL(string: "http://127.0.0.1:7717")!, targets: targets))
    }
}

/// A CDR that answers from memory and records what the toggle asked of it.
final class FakeCDR: CDRService, @unchecked Sendable {
    private let lock = NSLock()
    private var _installed = true
    private var _snapshotCalls = 0
    private var _requested: [Bool] = []
    private let current: CDRSnapshot
    var command: Result<CDRCommand, CDRCommandError> = .success(
        CDRCommand(node: URL(fileURLWithPath: "/usr/bin/false"), cli: URL(fileURLWithPath: "/nonexistent/cli.mjs"))
    )
    var failure: CDRCommandError?

    init(daemon: CDRDaemonState, reviews: CDRReviewsState, escalations: CDREscalations = .available([])) {
        current = CDRSnapshot(daemon: daemon, reviews: reviews, escalations: escalations)
    }

    var installed: Bool {
        get { lock.withLock { _installed } }
        set { lock.withLock { _installed = newValue } }
    }

    var snapshotCalls: Int { lock.withLock { _snapshotCalls } }
    var requested: [Bool] { lock.withLock { _requested } }

    var isInstalled: Bool { installed }

    func snapshot(command: CDRCommand?) async -> CDRSnapshot {
        lock.withLock { _snapshotCalls += 1 }
        return current
    }

    func resolveCommand(configured: String?) -> Result<CDRCommand, CDRCommandError> {
        command
    }

    func setDaemon(running: Bool, using command: CDRCommand) throws {
        lock.withLock { _requested.append(running) }
        if let failure { throw failure }
    }
}
