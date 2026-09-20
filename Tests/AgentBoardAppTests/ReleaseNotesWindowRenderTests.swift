import AgentBoardCore
import AppKit
import SwiftUI
import XCTest
@testable import AgentBoard

/// The release notes window, rasterized on its own. `ReleaseNotesBody` is a `VStack`, not a `List`,
/// so `cacheDisplay` reaches it — the route `GlanceCardAttentionRenderTests` uses.
///
/// What this proves: two mounts of the same notes differ in zero pixels; a third release adds
/// rendered height; and changing the *oldest* release's body changes the picture, so every entry in
/// the file is drawn rather than only the newest.
///
/// What it cannot prove: that any of it reads correctly. No string in a SwiftUI `Text` is legible on
/// this machine, so the version headings, the dates, the bullet glyph, the code-block background and
/// the wrapping have been compared and never read. Nobody has looked at these pixels.
@MainActor
final class ReleaseNotesWindowRenderTests: XCTestCase {
    private static let width: CGFloat = 560
    /// A fixed canvas rather than `fittingSize`, so two captures always have the same dimensions and
    /// a pixel count means something. Tall enough for three releases at this width.
    private static let canvas: CGFloat = 900

    private func notes(_ entries: [(String, String)], running: String = "0.3.0") -> ReleaseNotesState {
        .loaded(ReleaseNotes(
            appVersion: ReleaseVersion(running)!,
            entries: entries.map {
                ReleaseNotesEntry(version: ReleaseVersion($0.0)!, date: nil, body: $0.1)
            }
        ))
    }

    private let three: [(String, String)] = [
        ("0.3.0", "- **Newest.** The third release."),
        ("0.2.0", "- **Middle.** The second release."),
        ("0.1.0", "- **Oldest.** The first release."),
    ]

    private func host(_ state: ReleaseNotesState, height: CGFloat? = nil) -> NSHostingView<some View> {
        let host = NSHostingView(
            rootView: ReleaseNotesBody(document: ReleaseNotesDocument(state: state))
                .frame(width: Self.width, alignment: .leading)
                .background(Color(nsColor: .windowBackgroundColor))
        )
        host.layoutSubtreeIfNeeded()
        host.frame = NSRect(
            origin: .zero,
            size: CGSize(width: Self.width, height: height ?? max(host.fittingSize.height, 1))
        )
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func pixels(_ state: ReleaseNotesState) throws -> NSBitmapImageRep {
        let host = host(state, height: Self.canvas)
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private func height(_ state: ReleaseNotesState) -> CGFloat {
        host(state).fittingSize.height
    }

    private func differingPixels(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep) throws -> Int {
        XCTAssertEqual(lhs.pixelsWide, rhs.pixelsWide)
        XCTAssertEqual(lhs.pixelsHigh, rhs.pixelsHigh)
        XCTAssertGreaterThan(lhs.pixelsWide * lhs.pixelsHigh, 0, "nothing was rasterized")
        let left = try XCTUnwrap(lhs.representation(using: .png, properties: [:]))
        let right = try XCTUnwrap(rhs.representation(using: .png, properties: [:]))
        guard left != right else { return 0 }
        var differing = 0
        for y in 0..<lhs.pixelsHigh {
            for x in 0..<lhs.pixelsWide where lhs.colorAt(x: x, y: y) != rhs.colorAt(x: x, y: y) {
                differing += 1
            }
        }
        return differing
    }

    /// The control. Without it a pixel inequality below proves nothing, because two mounts could
    /// differ for any reason at all.
    func testTwoMountsOfTheSameNotesDifferInZeroPixels() throws {
        let state = notes(three)
        XCTAssertEqual(try differingPixels(try pixels(state), try pixels(state)), 0)
    }

    /// Every release in the file is drawn, not just the newest: each one adds rendered height.
    func testEachReleaseInTheFileAddsRenderedHeight() {
        let one = height(notes(Array(three.prefix(1))))
        let two = height(notes(Array(three.prefix(2))))
        let all = height(notes(three))
        XCTAssertGreaterThan(two, one, "a second release added no height, so it was not drawn")
        XCTAssertGreaterThan(all, two, "a third release added no height, so it was not drawn")
    }

    /// Height alone would also grow if the window drew three copies of the newest release. Changing
    /// only the *oldest* entry's body must change the picture, which it can only do if that entry's
    /// own text reaches the screen.
    func testChangingOnlyTheOldestReleaseChangesWhatIsDrawn() throws {
        var rewritten = three
        rewritten[2] = ("0.1.0", "- **Oldest.** Rewritten entirely, at a different length again.")
        XCTAssertGreaterThan(
            try differingPixels(try pixels(notes(three)), try pixels(notes(rewritten))),
            0,
            "the oldest release's body is not reaching the window"
        )
    }

    /// The canary for the two tests above: if `cacheDisplay` came back blank, every capture would be
    /// the same flat rectangle and a non-zero diff would be impossible to get. Notes must not draw
    /// like an empty document.
    func testNotesDoNotRasterizeToTheSamePictureAsNothingAtAll() throws {
        let empty = ReleaseNotesState.loaded(ReleaseNotes(appVersion: ReleaseVersion("0.3.0")!, entries: []))
        XCTAssertGreaterThan(try differingPixels(try pixels(notes(three)), try pixels(empty)), 0)
    }

    /// The newest release is not the only one whose body is drawn, and the middle one is not either.
    func testChangingOnlyTheMiddleReleaseChangesWhatIsDrawn() throws {
        var rewritten = three
        rewritten[1] = ("0.2.0", "- **Middle.** Also rewritten, at a noticeably different length.")
        XCTAssertGreaterThan(
            try differingPixels(try pixels(notes(three)), try pixels(notes(rewritten))), 0
        )
    }

    // MARK: the states with no releases in them

    /// The decision this task made: a build with no notes gets a window that says so, not a missing
    /// or greyed-out menu item. So the document must carry a sentence and must still render.
    func testAnUnbundledBuildRendersASentenceRatherThanNothing() throws {
        let document = ReleaseNotesDocument(state: .unavailable)
        XCTAssertTrue(document.sections.isEmpty)
        let notice = try XCTUnwrap(document.notice)
        XCTAssertTrue(notice.contains("RELEASES.md"), notice)
        XCTAssertGreaterThan(height(.unavailable), 0, "the no-notes window rendered nothing at all")
    }

    /// A build that ships an unparsable file has to show the parser's sentence, not swallow it.
    func testAFailedLoadPutsTheParsersSentenceInTheWindow() throws {
        let message = ReleaseNotesParseError.unreadableHeading(line: 3, heading: "Unreleased").description
        let document = ReleaseNotesDocument(state: .failed(message))
        XCTAssertTrue(try XCTUnwrap(document.notice).contains(message))
        XCTAssertNotEqual(
            try differingPixels(try pixels(.failed(message)), try pixels(.unavailable)), 0,
            "a broken notes file must not look like a build that ships none"
        )
    }

    func testTheRunningVersionIsMarkedAndTheOthersAreNot() {
        let document = ReleaseNotesDocument(state: notes(three, running: "0.2.0"))
        XCTAssertEqual(document.sections.map(\.title), ["0.3.0", "0.2.0", "0.1.0"])
        XCTAssertEqual(document.sections.map { $0.subtitle ?? "-" }, ["-", "this build", "-"])
    }
}
