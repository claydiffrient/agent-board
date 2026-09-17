import AgentBoardCore
import AppKit
import XCTest
@testable import AgentBoard

/// The three properties that keep a capture suite honest, asserted on their own rather than only
/// through the suites that rely on them.
///
/// `SidebarAttentionLiveTests` passed on its own and failed elsewhere with five spatial assertions
/// reporting a whole-sidebar difference where a 14-point badge was expected — `("430") is not less
/// than ("40")`, `("1203") is not less than ("40")`. None of those numbers came from the board. The
/// strip the diff ran over was the constant `0..<460`, 230 points doubled, and the window server on
/// a Mac with no display does not always capture at 2x.
@MainActor
final class OffscreenCaptureContractTests: XCTestCase {
    private var collapse = IsolatedCollapseState()

    override func setUp() {
        super.setUp()
        collapse = IsolatedCollapseState()
    }

    override func tearDown() {
        collapse.remove()
        super.tearDown()
    }

    private static let sidebar = 0..<230
    private static let loaded = SidebarContent(rows: 3, headers: 1)

    private func board() throws -> AppDatabase {
        let db = try AppDatabase.inMemory()
        for name in ["Alpha", "Beta"] {
            _ = try ProjectStore(db).register(
                name: name, repoPath: "/tmp/capture-contract-\(UUID().uuidString)",
                baseBranch: "main", worktreeRoot: "/tmp/capture-contract-worktrees", memoryDir: nil
            )
        }
        return db
    }

    private func mount(_ db: AppDatabase) -> OffscreenMount {
        OffscreenMount(MainWindow(collapseState: collapse.state).environment(renderEnvironment(db: db)))
    }

    /// The window the suite used to capture: up, drawable, and not yet showing the board.
    func testAFreshMountIsOnScreenBeforeItsObservationsHaveDelivered() throws {
        let mounted = mount(try board())
        defer { mounted.close() }
        XCTAssertNotEqual(
            mounted.sidebarContent, Self.loaded,
            "a mount that already showed its rows would make the rest of this class vacuous"
        )
    }

    /// The gate: a capture is of the board, not of whatever was on screen when the pixels stopped.
    func testACaptureWaitsForTheBoardRatherThanForThePixelsToHoldStill() throws {
        let mounted = mount(try board())
        defer { mounted.close() }
        _ = try mounted.capture(
            points: Self.sidebar, showing: Self.loaded
        )
        XCTAssertEqual(mounted.sidebarContent, Self.loaded)
    }

    /// And the ceiling: an expiry says so, instead of handing back a half-drawn window for the
    /// caller's own assertions to describe as a badge in the wrong place.
    func testACaptureThatNeverReachesItsContentFailsByName() throws {
        let mounted = mount(try board())
        defer { mounted.close() }
        XCTExpectFailure("a ceiling that expires without the content must fail here, and say so") {
            $0.compactDescription.contains("the window never settled")
        }
        _ = try mounted.capture(
            points: Self.sidebar,
            showing: SidebarContent(rows: 99, headers: 0), ceiling: .seconds(1)
        )
    }

    /// The strip is a number of points, and the pixels it covers are that image's own business.
    ///
    /// Both scales are measured, on this machine on 2026-09-16: the same 1100x700 window came back
    /// 1982x1262 at 21:33 and 2200x1400 half an hour later. The sidebar ends at 230 points in both.
    /// The pixel constant `0..<460` is right for one of them and 25 points into the At a Glance
    /// headline in the other, which is the whole of the bug this class exists for.
    func testAStripInPointsCoversTheSidebarAtEitherMeasuredScale() {
        XCTAssertEqual(
            Capture.columns(Self.sidebar, capturedWidth: 2200, windowWidth: 1100), 0..<460,
            "2.0x, the scale the pixel constant was written for"
        )
        XCTAssertEqual(
            Capture.columns(Self.sidebar, capturedWidth: 1982, windowWidth: 1100), 0..<414,
            "1.80x, where that same constant overran the sidebar by 25 points"
        )
    }

    /// An open-ended strip is the rest of the image, not an overflow.
    func testADetailStripRunsToTheEdgeOfWhateverWasCaptured() {
        XCTAssertEqual(
            Capture.columns(230..<Int.max, capturedWidth: 1982, windowWidth: 1100), 414..<1982
        )
    }

    /// And the live one: a capture converts its own strip, so the pair being diffed always agree.
    func testACaptureConvertsItsStripAgainstTheImageTheWindowServerHandedBack() throws {
        let mounted = mount(try board())
        defer { mounted.close() }
        let shot = try mounted.capture(points: Self.sidebar, showing: Self.loaded)
        XCTAssertEqual(
            shot.columns(Self.sidebar),
            Capture.columns(Self.sidebar, capturedWidth: shot.width, windowWidth: shot.windowWidth)
        )
        XCTAssertLessThan(
            shot.columns(Self.sidebar).upperBound, shot.width,
            "230 points of an 1100-point window cannot be the whole capture"
        )
    }
}
