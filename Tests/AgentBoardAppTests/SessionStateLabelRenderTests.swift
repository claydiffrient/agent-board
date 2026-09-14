import AgentBoardCore
import AppKit
import SwiftUI
import XCTest
@testable import AgentBoard

/// Offscreen render of the Status table's State cell. No display is available to a background
/// agent, so the states are compared by rasterizing the real view rather than by driving the app.
@MainActor
final class SessionStateLabelRenderTests: XCTestCase {
    private func render(_ state: SessionState) throws -> Data {
        let hosting = NSHostingView(
            rootView: SessionStateLabel(state: state)
                .frame(width: 120, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
        )
        hosting.layoutSubtreeIfNeeded()
        hosting.frame = NSRect(origin: .zero, size: CGSize(width: 120, height: max(hosting.fittingSize.height, 1)))
        hosting.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    func testSetupDoesNotLookLikeARunningWorker() throws {
        XCTAssertNotEqual(try render(.setup), try render(.running))
        XCTAssertNotEqual(try render(.setup), try render(.starting))
    }

    func testSetupReadsAsAPhaseNotAState() {
        XCTAssertEqual(SessionState.setup.label, "setting up")
        XCTAssertNotNil(SessionState.setup.help)
        for state in SessionState.allCases where state != .setup {
            XCTAssertEqual(state.label, state.rawValue)
        }
    }
}
