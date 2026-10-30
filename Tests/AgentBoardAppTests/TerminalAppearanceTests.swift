import AppKit
import SwiftTerm
import SwiftUI
import XCTest
@testable import AgentBoard

@MainActor
final class TerminalAppearanceTests: XCTestCase {
    private var suite = ""

    override func setUp() {
        suite = "TerminalAppearanceTests.\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private func store() -> TerminalAppearanceStore {
        TerminalAppearanceStore(defaults: UserDefaults(suiteName: suite)!)
    }

    func testAnEmptyStoreHoldsTheDefaultsAndAnEditSurvivesARelaunch() {
        XCTAssertEqual(store().appearance, .defaults)

        var edited = TerminalAppearance.defaults
        edited.fontFamily = "Menlo"
        edited.fontSize = 15
        edited.background = TerminalColor(0x102030)
        edited.palette[4] = TerminalColor(0xabcdef)
        store().appearance = edited

        let relaunched = store()
        XCTAssertEqual(relaunched.appearance, edited)

        relaunched.restoreDefaults()
        XCTAssertEqual(store().appearance, .defaults)
    }

    func testAMissingFamilyFallsBackToTheMonospacedSystemFont() {
        var appearance = TerminalAppearance.defaults
        appearance.fontFamily = "No Such Family \(UUID().uuidString)"
        appearance.fontSize = 14
        XCTAssertEqual(appearance.font, NSFont.monospacedSystemFont(ofSize: 14, weight: .regular))
    }

    func testAnAttachedTerminalTakesTheAppearanceAndFollowsLaterEdits() {
        let appearances = store()
        let terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        appearances.attach(terminal)

        XCTAssertEqual(TerminalColor(terminal.nativeBackgroundColor), TerminalColor(0x011627))
        XCTAssertEqual(TerminalColor(terminal.nativeForegroundColor), TerminalColor(0xd6deeb))
        XCTAssertEqual(TerminalColor(terminal.caretColor), TerminalColor(0x7e57c2))
        XCTAssertEqual(TerminalColor(terminal.selectedTextBackgroundColor), TerminalColor(0x5f7e97))
        XCTAssertEqual(terminal.font, TerminalAppearance.defaults.font)

        appearances.appearance.background = TerminalColor(0x202020)
        appearances.appearance.fontSize = 18

        XCTAssertEqual(TerminalColor(terminal.nativeBackgroundColor), TerminalColor(0x202020))
        XCTAssertEqual(terminal.font.pointSize, 18)
    }

    /// CI runners may have no usable Metal device, so a recorded fallback counts as asking for it.
    func testAnAttachedTerminalAsksForMetalByDefaultAndTurningItOffRevertsLive() {
        let appearances = store()
        let terminal = BoardTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        appearances.attach(terminal)

        XCTAssertTrue(terminal.isUsingMetalRenderer || appearances.metalFailure != nil)
        if appearances.metalFailure != nil {
            XCTAssertFalse(terminal.isUsingMetalRenderer)
        }

        appearances.usesMetal = false
        XCTAssertFalse(terminal.isUsingMetalRenderer)
        XCTAssertFalse(store().usesMetal)
    }

    /// `ColorPicker` mounts as a real `NSColorWell`, whose `color` is readable offscreen.
    func testThePaneShowsTheStoredColorsAndRestoreDefaultsRepaintsThem() throws {
        let appearances = store()
        appearances.appearance.background = TerminalColor(0x334455)
        appearances.appearance.palette[3] = TerminalColor(0x998877)
        let mount = OffscreenMount(TerminalSettingsPane(store: appearances), size: CGSize(width: 560, height: 1200))
        defer { mount.close() }

        func shownColors() throws -> [TerminalColor] {
            _ = try mount.capture()
            var wells: [NSColorWell] = []
            func walk(_ view: NSView) {
                if let well = view as? NSColorWell { wells.append(well) }
                view.subviews.forEach(walk)
            }
            walk(mount.host)
            return wells.map { TerminalColor($0.color) }
        }
        func expected(_ appearance: TerminalAppearance) -> [TerminalColor] {
            [
                appearance.foreground, appearance.background, appearance.cursor, appearance.cursorText,
                appearance.selectionBackground, appearance.selectionForeground,
            ] + appearance.palette
        }

        XCTAssertEqual(try shownColors(), expected(appearances.appearance))

        appearances.restoreDefaults()
        XCTAssertEqual(try shownColors(), expected(.defaults))
    }
}
