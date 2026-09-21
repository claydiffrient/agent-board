import AgentBoardCore
import AppKit
import SwiftUI
import XCTest
@testable import AgentBoard

/// The attention indicator on a single At a Glance card, rasterized on its own.
///
/// What this proves: a card for a project that needs a human draws differently from the same card
/// without the signal, at the grid's 220-point minimum and at its 320-point maximum, and for a
/// busy board as well as an idle one. A card is a plain `VStack`, not a `List` row, so
/// `cacheDisplay` reaches it — the same route `ProjectRowBadgeRenderTests` uses for the sidebar row.
///
/// What it cannot prove: that the dot is the right size or colour, that it reads as separate from
/// the name, or that its tooltip appears on hover. Nobody has looked at these pixels — they have
/// only been compared, and `.help()` leaves no readable string in the AppKit or accessibility
/// trees on this machine.
@MainActor
final class GlanceCardAttentionRenderTests: XCTestCase {
    private func glance(_ name: String, running: Int = 0, review: Int = 0, ready: Int = 0) -> ProjectGlance {
        ProjectGlance(id: "p-\(name)", name: name, running: running, review: review, ready: ready)
    }

    private func waiting(_ glance: ProjectGlance, _ causes: [AttentionCause]) -> ProjectAttention {
        ProjectAttention(id: glance.id, name: glance.name, causes: causes)
    }

    private func pixels(_ glance: ProjectGlance, _ attention: ProjectAttention?, width: CGFloat) throws -> Data {
        let hosting = NSHostingView(
            rootView: ProjectGlanceCard(glance: glance, attention: attention)
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

    /// The control: without it a pixel inequality proves nothing, because two mounts could differ
    /// for any reason at all.
    func testTwoMountsOfTheSameQuietCardAreIdentical() throws {
        let alpha = glance("Alpha", running: 2, review: 1, ready: 3)
        XCTAssertEqual(try pixels(alpha, nil, width: 220), try pixels(alpha, nil, width: 220))
    }

    func testACardThatNeedsTheHumanDoesNotDrawLikeOneThatDoesNot() throws {
        let alpha = glance("Alpha", running: 2, review: 1, ready: 3)
        XCTAssertNotEqual(
            try pixels(alpha, waiting(alpha, [AttentionCause(reason: .pendingApproval, count: 1)]), width: 220),
            try pixels(alpha, nil, width: 220),
            "a project needing attention must not draw the same as one that does not"
        )
    }

    /// A project needing attention but carrying no causes is not needing attention. The card must
    /// tell those apart, or an empty roll-up would mark every project.
    func testAnEmptyCauseListDrawsExactlyLikeNoSignalAtAll() throws {
        let alpha = glance("Alpha", running: 2, review: 1, ready: 3)
        XCTAssertEqual(
            try pixels(alpha, waiting(alpha, []), width: 220), try pixels(alpha, nil, width: 220)
        )
    }

    /// `LazyVGrid(.adaptive(minimum: 220, maximum: 320))`: the indicator has to survive both ends,
    /// and a long name is what squeezes it at the narrow one.
    func testTheIndicatorSurvivesBothEndsOfTheAdaptiveGrid() throws {
        let long = glance("a-project-with-a-name-long-enough-to-truncate", running: 1)
        let signal = waiting(long, [AttentionCause(reason: .blockedWorker, count: 1, detail: "Wire the thing")])
        for width in [CGFloat(220), 320] {
            XCTAssertNotEqual(
                try pixels(long, signal, width: width), try pixels(long, nil, width: width),
                "the indicator must survive a \(Int(width))-point card"
            )
        }
    }

    /// An idle board with a pending approval is the case the review-count proxy missed entirely.
    func testAnIdleCardStillShowsTheIndicator() throws {
        let quiet = glance("Quiet")
        XCTAssertTrue(quiet.isIdle)
        XCTAssertNotEqual(
            try pixels(quiet, waiting(quiet, [AttentionCause(reason: .pendingApproval, count: 1)]), width: 220),
            try pixels(quiet, nil, width: 220)
        )
    }
}

/// The tooltip string is a pure value, so it is checked as one: `.help()` does not reach
/// `NSView.toolTip`, so the fact that the card *carries* it is verified by reading
/// `ProjectGlanceCard`, not by a test.
final class GlanceCardAttentionReasonTests: XCTestCase {
    /// The card, the sidebar badge and the notification body all read `ProjectAttention.summary`.
    /// This pins the string the card hands to `.help()` so a divergence would fail here.
    func testTheCardsTooltipIsTheSignalsOwnSummary() {
        let attention = ProjectAttention(
            id: "p1", name: "Alpha",
            causes: [
                AttentionCause(reason: .pendingApproval, count: 2),
                AttentionCause(reason: .blockedWorker, count: 1, detail: "Wire the thing"),
            ]
        )
        XCTAssertEqual(attention.summary, "2 approvals waiting, 1 worker blocked: Wire the thing.")
    }

    func testAQuietProjectHasNoTooltipAndThereforeNoIndicator() {
        XCTAssertNil(ProjectAttention(id: "p1", name: "Alpha", causes: []).summary)
    }
}

/// The page against a real database, to prove it is wired to the signal and not to an empty array.
///
/// `MainWindow` lands on At a Glance, so mounting it and capturing everything to the right of the
/// sidebar captures the page. A pending approval written into the live database must change those
/// pixels with no manual re-render, and resolving it must restore them.
///
/// The mount and the capture are `OffscreenMount`'s: it captures only once the picture has stopped
/// moving, rather than after a fixed pump, and `renderEnvironment` keeps the sidebar footer from
/// drawing so no background read can land mid-capture.
///
/// What this proves: the page reads `ProjectAttentionStore` through the observation `MainWindow`
/// already runs, and reacts to it live. What it cannot prove: which of the headline and the card
/// changed, or what either now says — the capture is a comparison, not a reading.
@MainActor
final class AtAGlanceAttentionLiveTests: XCTestCase {
    /// The 220-point sidebar plus its inset; everything past it is the detail pane, which is the At
    /// a Glance page. In window points, not capture pixels.
    ///
    /// This was the pixel constant `460..<Int.max`. The capture scale on a Mac with no display is
    /// neither 2 nor stable across a session, and above 2 that constant starts inside the sidebar —
    /// whose badge changes with the same approval this page is watching. See `Capture.columns(_:)`.
    private static let detail = 230..<Int.max

    private var collapse = IsolatedCollapseState()

    private func mount(_ db: AppDatabase) -> OffscreenMount {
        OffscreenMount(MainWindow(collapseState: collapse.state).environment(renderEnvironment(db: db)))
    }

    private func detailDiff(_ a: Capture, _ b: Capture) -> Int {
        a.diff(b, columns: a.columns(Self.detail)).count
    }

    private func register(_ db: AppDatabase, _ name: String) throws -> Project {
        try ProjectStore(db).register(
            name: name, repoPath: "/tmp/glance-attention-\(UUID().uuidString)", baseBranch: "main",
            worktreeRoot: "/tmp/glance-attention-worktrees", memoryDir: nil
        )
    }

    override func setUp() {
        super.setUp()
        collapse = IsolatedCollapseState()
    }

    override func tearDown() {
        collapse.remove()
        super.tearDown()
    }

    /// The control: without it a pixel difference proves only that two captures are not equal.
    func testTwoMountsOfTheSameQuietPageAreIdentical() throws {
        let db = try AppDatabase.inMemory()
        _ = try register(db, "Alpha")
        collapse.state.save([])

        let first = mount(db)
        let second = mount(db)
        defer { first.close(); second.close() }
        XCTAssertEqual(
            detailDiff(try first.capture(points: Self.detail), try second.capture(points: Self.detail)), 0,
            "the page must render deterministically"
        )
    }

    func testAPendingApprovalChangesThePageAndResolvingItRestoresIt() throws {
        let db = try AppDatabase.inMemory()
        let alpha = try register(db, "Alpha")
        _ = try register(db, "Beta")
        collapse.state.save([])

        let page = mount(db)
        defer { page.close() }
        let quiet = try page.capture(points: Self.detail)

        let approval = try ApprovalStore(db).create(
            projectId: alpha.id, kind: .spawn, taskId: nil, epicId: nil,
            requestedBy: "orchestrator", reason: "spawn a worker"
        )
        XCTAssertGreaterThan(
            detailDiff(quiet, try page.capture(points: Self.detail) { self.detailDiff(quiet, $0) > 0 }), 0,
            "a pending approval must reach the page, which is what the review-column proxy missed"
        )

        try ApprovalStore(db).resolve(approval.id, .denied)
        XCTAssertEqual(
            detailDiff(quiet, try page.capture(points: Self.detail) { self.detailDiff(quiet, $0) == 0 }), 0,
            "resolving the approval must restore the quiet page exactly"
        )
    }

    /// The test above cannot tell the headline changing from a card being marked, because a pending
    /// approval moves both. Two boards with one waiting project each render the same headline word
    /// for word — "1 project needs you. Nothing running, nothing awaiting your review." — so any
    /// difference between them is the indicator sitting on a different card.
    func testTheIndicatorLandsOnTheWaitingProjectsOwnCard() throws {
        func board(waiting: Int) throws -> AppDatabase {
            let db = try AppDatabase.inMemory()
            let projects = try ["Alpha", "Beta"].map { try register(db, $0) }
            _ = try ApprovalStore(db).create(
                projectId: projects[waiting].id, kind: .spawn, taskId: nil, epicId: nil,
                requestedBy: "orchestrator", reason: nil
            )
            return db
        }
        collapse.state.save([])

        let first = mount(try board(waiting: 0))
        let second = mount(try board(waiting: 1))
        defer { first.close(); second.close() }
        XCTAssertGreaterThan(
            detailDiff(try first.capture(points: Self.detail), try second.capture(points: Self.detail)), 0,
            "the same headline over a differently-marked card must not render identically"
        )
    }
}
