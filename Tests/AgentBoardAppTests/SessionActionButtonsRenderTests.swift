import AgentBoardCore
import AppKit
import SwiftUI
import XCTest
@testable import AgentBoard

/// The shipped attach and worktree-shell pair, rasterized at the size it ships at.
///
/// A button group is a plain `HStack`, not a `List` row, so `cacheDisplay` reaches it — the same
/// route `GlanceCardAttentionRenderTests` uses. `.environment(\.controlActiveState, .active)` is on
/// every mount because an `.accessory` process otherwise draws every control in its inactive
/// appearance, which is exactly the colour these tests are looking for.
///
/// What these cannot prove: that a human reads a speech bubble as "the agent" or a terminal as
/// "its worktree". Nobody has looked at these pixels; they have only been compared.
@MainActor
final class SessionActionButtonsRenderTests: XCTestCase {
    private struct Raster {
        let width: Int
        let height: Int
        let pixels: [[UInt8]]

        var background: [UInt8] { pixels[0] }

        func isInk(_ i: Int) -> Bool {
            zip(pixels[i], background).contains { abs(Int($0) - Int($1)) > 8 }
        }
    }

    private func session(worktreePath: String? = "/tmp/worktrees/w1") -> AgentSession {
        AgentSession(
            sessionId: "session-1", shortId: "abcdef12", projectId: "p-1", role: .worker,
            worktreePath: worktreePath, cwd: "/tmp/repo", state: .running
        )
    }

    private func pair(
        _ session: AgentSession,
        showsTitle: Bool,
        attach: SessionAction = .attach,
        worktreeShell: SessionAction = .worktreeShell
    ) -> some View {
        HStack(spacing: 4) {
            SessionActionButtons(
                session: session, showsTitle: showsTitle, attach: attach, worktreeShell: worktreeShell
            )
        }
        .controlSize(.small)
        .padding(6)
    }

    private func hosting(_ view: some View, dark: Bool = false) -> NSHostingView<some View> {
        let host = NSHostingView(
            rootView: view
                .environment(\.controlActiveState, .active)
                .background(Color(nsColor: .controlBackgroundColor))
        )
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        return host
    }

    /// A fixed `size` leading-aligns the group, so the first button's origin is the same in every
    /// raster even when two glyphs have different intrinsic widths.
    private func raster(_ view: some View, size: CGSize? = nil, dark: Bool = false) throws -> Raster {
        let host = size.map {
            hosting(view.frame(width: $0.width, height: $0.height, alignment: .leading), dark: dark)
        } ?? hosting(view, dark: dark)
        host.layoutSubtreeIfNeeded()
        let frame = size ?? host.fittingSize
        host.frame = NSRect(origin: .zero, size: frame)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        var pixels: [[UInt8]] = []
        pixels.reserveCapacity(width * height)
        for y in 0..<height {
            for x in 0..<width {
                let color = try XCTUnwrap(rep.colorAt(x: x, y: y))
                pixels.append([
                    UInt8(clamping: Int(color.redComponent * 255)),
                    UInt8(clamping: Int(color.greenComponent * 255)),
                    UInt8(clamping: Int(color.blueComponent * 255)),
                ])
            }
        }
        return Raster(width: width, height: height, pixels: pixels)
    }

    /// Differing pixels, and the count of pixels either raster paints over its background. The ink
    /// union is the honest denominator: the frame is mostly empty, so a share of the whole raster
    /// would flatter any difference at all.
    private func compare(_ a: Raster, _ b: Raster) throws -> (differing: Int, ink: Int) {
        XCTAssertEqual(a.width, b.width)
        XCTAssertEqual(a.height, b.height)
        var differing = 0
        var ink = 0
        for i in 0..<min(a.pixels.count, b.pixels.count) {
            if a.pixels[i] != b.pixels[i] { differing += 1 }
            if a.isInk(i) || b.isInk(i) { ink += 1 }
        }
        return (differing, ink)
    }

    /// The control. Without it a pixel inequality proves nothing, because two mounts could differ
    /// for any reason at all.
    func testTwoMountsOfTheSameButtonDifferInZeroPixels() throws {
        let view = pair(session(), showsTitle: false)
        let box = CGSize(width: 110, height: 34)
        let result = try compare(try raster(view, size: box), try raster(view, size: box))
        XCTAssertEqual(result.differing, 0)
        XCTAssertGreaterThan(result.ink, 0, "an all-background raster would make every diff below vacuous")
    }

    /// The whole point of the change: at the size these ship at, the two glyphs are not one shape
    /// twice. Both slots are given the same descriptor so every differing pixel is glyph against
    /// glyph, with identical chrome, spacing, control size and origin on both sides.
    ///
    /// The threshold is calibrated against the pair this replaced rather than guessed, and that
    /// pair turns out to be worse than "similar": `terminal` and `apple.terminal` are the same
    /// image on this OS — `NSImage(systemSymbolName:)` returns byte-identical TIFF for both — so
    /// they separate across **0%** of their ink at every size measured, up to 96pt.
    /// `bubble.left.fill` beside `apple.terminal` separates across 38.0%. Requiring a fifth of the
    /// ink outright, and a fifth more than the old pair managed, fails the moment anyone puts a
    /// second terminal glyph back.
    ///
    /// Ink, not the whole raster, is the denominator: the frame is mostly empty, and both buttons
    /// draw identical bordered chrome that lands in the denominator but never the numerator, so
    /// even two wholly unrelated glyphs cannot approach 100%.
    func testTheAttachAndWorktreeGlyphsSeparateFarBetterThanThePairTheyReplaced() throws {
        func separation(_ a: String, _ b: String) throws -> Double {
            let box = CGSize(width: 110, height: 34)
            func both(_ symbol: String) -> SessionAction {
                SessionAction(symbol: symbol, title: "x", accessibilityLabel: "x")
            }
            let left = try raster(
                pair(session(), showsTitle: false, attach: both(a), worktreeShell: both(a)), size: box
            )
            let right = try raster(
                pair(session(), showsTitle: false, attach: both(b), worktreeShell: both(b)), size: box
            )
            let result = try compare(left, right)
            return Double(result.differing) / Double(result.ink)
        }
        let shipped = try separation(SessionAction.attach.symbol, SessionAction.worktreeShell.symbol)
        let replaced = try separation("terminal", "apple.terminal")
        print("PROBE separation shipped=\(shipped) replaced=\(replaced)")
        XCTAssertGreaterThan(shipped, 0.2, "the two buttons must not read as one shape twice")
        XCTAssertGreaterThan(
            shipped, replaced + 0.2,
            "the shipped pair must separate far better than the two terminal glyphs it replaced"
        )
    }

    /// The Actions column is width-constrained and a title truncates to `Ag…` there, so it renders
    /// icon only. Changing both titles to strings nothing else shares must move zero pixels: if any
    /// of the title reached the raster, it would not.
    func testTheStatusColumnDrawsNoTitleText() throws {
        let box = CGSize(width: 110, height: 34)
        let shipped = try raster(pair(session(), showsTitle: false), size: box)
        let renamed = try raster(
            pair(
                session(),
                showsTitle: false,
                attach: SessionAction(symbol: SessionAction.attach.symbol, title: "Wwwwwwwwww", accessibilityLabel: "a"),
                worktreeShell: SessionAction(
                    symbol: SessionAction.worktreeShell.symbol, title: "Mmmmmmmmmm", accessibilityLabel: "b"
                )
            ),
            size: box
        )
        XCTAssertEqual(try compare(shipped, renamed).differing, 0, "the Actions column drew a title")
    }

    /// The inspector row is not width-constrained the same way and reads `Agent` / `Shell`. The
    /// same substitution must move pixels here — that the strings are those two words is pinned by
    /// `SessionActionButtonsTests.testTheTitlesAreAgentAndShell`.
    func testTheInspectorRowDrawsBothTitles() throws {
        let shipped = try raster(pair(session(), showsTitle: true), size: CGSize(width: 220, height: 40))
        for substitute in [
            SessionAction(symbol: SessionAction.attach.symbol, title: "Wwww", accessibilityLabel: "a"),
            SessionAction(symbol: SessionAction.worktreeShell.symbol, title: "Mmmm", accessibilityLabel: "b"),
        ] {
            let renamed = try raster(
                pair(
                    session(),
                    showsTitle: true,
                    attach: substitute.title == "Wwww" ? substitute : .attach,
                    worktreeShell: substitute.title == "Mmmm" ? substitute : .worktreeShell
                ),
                size: CGSize(width: 220, height: 40)
            )
            XCTAssertGreaterThan(
                try compare(shipped, renamed).differing, 0,
                "changing one title moved nothing, so that title is not being drawn"
            )
        }
    }

    /// Candidate 3's accent bubble was rejected. Nothing either button draws may carry a hue: every
    /// pixel has to be grey, in both appearances. An accent fill is roughly (0, 122, 255) — a
    /// channel spread of 255 — against the 12 allowed here for antialiasing and the
    /// slightly-warm control background.
    func testNothingEitherButtonDrawsCarriesAHue() throws {
        for dark in [false, true] {
            let shipped = try raster(
                pair(session(), showsTitle: false), size: CGSize(width: 110, height: 34), dark: dark
            )
            var worst = 0
            for pixel in shipped.pixels {
                let spread = Int(pixel.max()!) - Int(pixel.min()!)
                worst = max(worst, spread)
            }
            print("PROBE hue dark=\(dark) worstChannelSpread=\(worst)")
            XCTAssertLessThanOrEqual(worst, 12, "a tinted or prominent button put colour back in (dark=\(dark))")
        }
    }

    /// A session with no worktree still draws its attach button identically, so every differing
    /// pixel is the worktree button being dimmed by `.disabled`. Holding the other button constant
    /// is what attributes the diff to the right control.
    func testTheWorktreeButtonDimsWhenItCannotOpen() throws {
        let box = CGSize(width: 110, height: 34)
        let open = try raster(pair(session(worktreePath: "/tmp/worktrees/w1"), showsTitle: false), size: box)
        let closed = try raster(pair(session(worktreePath: nil), showsTitle: false), size: box)
        XCTAssertGreaterThan(
            try compare(open, closed).differing, 0,
            "a session with no worktree must not draw an enabled shell button"
        )
    }

    /// The width the Actions column now needs. `TableColumn("Actions").width(min: 150, ideal: 170)`
    /// was sized for the group this replaced; this records what the icon-only group actually costs
    /// so a later widening is a decision rather than a drift.
    func testTheIconOnlyActionsGroupFitsWellInsideTheColumnMinimum() throws {
        func width(showsTitle: Bool) -> CGFloat {
            let host = hosting(
                HStack(spacing: 4) {
                    SessionActionButtons(session: session(), showsTitle: showsTitle)
                    Button("Resume") {}
                }
                .controlSize(.small)
            )
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.width
        }
        let iconOnly = width(showsTitle: false)
        let titled = width(showsTitle: true)
        print("PROBE actions group iconOnly=\(iconOnly) titled=\(titled)")
        XCTAssertLessThan(iconOnly, 150, "the icon-only group no longer needs the column's 150pt minimum")
        XCTAssertLessThan(iconOnly, titled, "titles would cost the column width it does not have")
    }
}
