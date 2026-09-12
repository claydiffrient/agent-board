import AgentBoardRuntime
import AppKit
import SwiftUI
import XCTest
@testable import AgentBoard

/// Offscreen render of the sidebar footer. No display is available to a background agent, so the
/// bars are checked by rasterizing the real view rather than by driving the app.
@MainActor
final class AccountUsageRenderTests: XCTestCase {
    private func render(_ view: some View, width: CGFloat = 220, name: String) throws -> NSBitmapImageRep {
        let hosting = NSHostingView(rootView: view.frame(width: width).background(Color(nsColor: .controlBackgroundColor)))
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: CGSize(width: width, height: max(size.height, 1)))
        hosting.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        if let dir = ProcessInfo.processInfo.environment["ACCOUNT_USAGE_RENDER_DIR"],
           let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        return rep
    }

    private func stack(_ windows: [(String, AccountUsageWindow)], isStale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(windows, id: \.0) { label, window in
                AccountUsageBar(label: label, window: window, now: .now, isStale: isStale)
            }
        }
        .padding(10)
    }

    func testFreshBarsRenderNonEmpty() throws {
        let rep = try render(
            stack([
                ("5h", AccountUsageWindow(percent: 54, resetsAt: Date(timeIntervalSince1970: 1789238400))),
                ("7d", AccountUsageWindow(percent: 67, resetsAt: Date(timeIntervalSince1970: 1789419600))),
            ], isStale: false),
            name: "fresh"
        )
        XCTAssertGreaterThan(rep.pixelsHigh, 40, "two bars with labels and reset lines must occupy real height")
    }

    func testStaleBarsRenderDimmerThanFreshOnes() throws {
        let windows = [("5h", AccountUsageWindow(percent: 92, resetsAt: Date(timeIntervalSince1970: 1789238400)))]
        let fresh = try render(stack(windows, isStale: false), name: "critical-fresh")
        let stale = try render(stack(windows, isStale: true), name: "critical-stale")

        XCTAssertNotEqual(Self.pixelDigest(fresh), Self.pixelDigest(stale), "a stale reading must not render identically to a current one")
    }

    private static func pixelDigest(_ rep: NSBitmapImageRep) -> Int {
        var hash = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                hash = hash &* 31 &+ Int(color.redComponent * 255)
                hash = hash &* 31 &+ Int(color.greenComponent * 255)
                hash = hash &* 31 &+ Int(color.blueComponent * 255)
            }
        }
        return hash
    }
}

@MainActor
extension AccountUsageRenderTests {
    private func fixtureConfig(fetchedAtMs: Int64, name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).json")
        try """
        {"cachedUsageUtilization": {"fetchedAtMs": \(fetchedAtMs), "utilization": {
          "five_hour": {"utilization": 54, "resets_at": "2026-09-12T18:40:00.263555+00:00"},
          "seven_day": {"utilization": 67, "resets_at": "2026-09-14T21:00:00.263579+00:00"}}}}
        """.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testFooterRendersBothWindowsAndTheAgeOfTheReading() async throws {
        let fresh = AccountUsageModel(
            configURL: try fixtureConfig(fetchedAtMs: Int64(Date.now.timeIntervalSince1970 * 1000) - 120_000, name: "fresh"),
            refresher: AccountUsageRefresher { _ in false }
        )
        let stale = AccountUsageModel(
            configURL: try fixtureConfig(fetchedAtMs: Int64(Date.now.timeIntervalSince1970 * 1000) - 3 * 3_600_000, name: "stale"),
            refresher: AccountUsageRefresher { _ in false }
        )
        for (model, name) in [(fresh, "footer-fresh"), (stale, "footer-stale")] {
            let task = _Concurrency.Task { await model.run() }
            try await _Concurrency.Task.sleep(for: .milliseconds(300))
            task.cancel()
            XCTAssertNotNil(model.snapshot, "\(name) fixture must have been read")
            _ = try render(AccountUsageFooter(model: model), name: name)
        }
    }
}
