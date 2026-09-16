import AgentBoardCore
import AgentBoardRuntime
import AppKit
import SwiftUI
import XCTest
@testable import AgentBoard

/// The pixels of one window-server capture, held as raw bytes.
///
/// `NSBitmapImageRep.colorAt(x:y:)` returns an optional, so a diff written over it silently reports
/// zero differences for a rep it cannot read — which reads exactly like "the change never rendered".
/// Reading `bitmapData` once and failing loudly if it is nil removes that failure mode, and is two
/// orders of magnitude faster besides.
struct Capture {
    let width: Int
    let height: Int
    private let rowBytes: Int
    private let samplesPerPixel: Int
    private let bytes: [UInt8]

    init(_ rep: NSBitmapImageRep, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try XCTUnwrap(rep.bitmapData, "the capture has no readable bitmap data", file: file, line: line)
        width = rep.pixelsWide
        height = rep.pixelsHigh
        rowBytes = rep.bytesPerRow
        samplesPerPixel = rep.samplesPerPixel
        let total = rowBytes * height
        bytes = [UInt8](UnsafeBufferPointer(start: data, count: total))
    }

    /// Differing pixels and their bounding box over `columns`.
    ///
    /// A channel sum above 5/255 is the same threshold the `colorAt` version used (`> 0.02`
    /// summed over normalized R+G+B); both count a pixel from a byte sum of 6 upward. Measured to
    /// agree on the sidebar badge: 172 pixels in a 14x14 box, either way.
    func diff(_ other: Capture, columns: Range<Int>) -> PixelDiff {
        var box = PixelDiff()
        guard samplesPerPixel == other.samplesPerPixel, rowBytes == other.rowBytes else { return box }
        let stop = min(height, other.height)
        let from = max(0, columns.lowerBound)
        let to = min(columns.upperBound, width, other.width)
        guard from < to else { return box }
        let stride = samplesPerPixel
        bytes.withUnsafeBufferPointer { left in
            other.bytes.withUnsafeBufferPointer { right in
                for y in 0..<stop {
                    let row = y * rowBytes
                    for x in from..<to {
                        let i = row + x * stride
                        let apart = abs(Int(left[i]) - Int(right[i]))
                            + abs(Int(left[i + 1]) - Int(right[i + 1]))
                            + abs(Int(left[i + 2]) - Int(right[i + 2]))
                        guard apart > 5 else { continue }
                        box.count += 1
                        box.minX = min(box.minX, x); box.maxX = max(box.maxX, x)
                        box.minY = min(box.minY, y); box.maxY = max(box.maxY, y)
                    }
                }
            }
        }
        return box
    }

    /// True when every pixel is the same colour.
    ///
    /// The window server hands back a flat surface for a window it has not composited yet, and a
    /// flat surface is as stable as a settled one — so a stability poll on its own would accept it,
    /// and two such captures of two different boards would compare equal. No mounted screen in this
    /// app is one colour, so this can be rejected outright.
    var isBlank: Bool {
        guard width > 0, height > 0 else { return true }
        let stride = samplesPerPixel
        var flat = true
        bytes.withUnsafeBufferPointer { px in
            let r = Int(px[0]), g = Int(px[1]), b = Int(px[2])
            for y in 0..<height {
                let row = y * rowBytes
                for x in 0..<width {
                    let i = row + x * stride
                    if abs(Int(px[i]) - r) + abs(Int(px[i + 1]) - g) + abs(Int(px[i + 2]) - b) > 5 {
                        flat = false
                        return
                    }
                }
            }
        }
        return flat
    }
}

struct PixelDiff {
    var count = 0
    var minX = Int.max
    var maxX = -1
    var minY = Int.max
    var maxY = -1

    var width: Int { maxX < 0 ? 0 : maxX - minX + 1 }
    var height: Int { maxY < 0 ? 0 : maxY - minY + 1 }
}

/// A SwiftUI view mounted in a borderless window far offscreen, captured through the window server.
///
/// Borderless matters: AppKit drags a `.titled` window back onto a visible display, and a worker on
/// this project has none. `CGWindowListCreateImage` is the one route that rasterizes a SwiftUI
/// `List`; `cacheDisplay` and `ImageRenderer` come back blank for list content.
@MainActor
final class OffscreenMount {
    let window: NSWindow
    let host: NSView

    init(_ rootView: some View, size: CGSize = CGSize(width: 1100, height: 700)) {
        host = NSHostingView(rootView: rootView)
        NSApplication.shared.setActivationPolicy(.accessory)
        window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderBack(nil)
    }

    func close() { window.orderOut(nil) }

    /// Pumps the main run loop until the picture stops moving — and, when `until` is given, until
    /// it also satisfies that condition.
    ///
    /// A fixed pump is a guess at three asynchronous hops at once: a GRDB `ValueObservation`
    /// delivering on the main actor, SwiftUI applying it to the view tree, and the window server
    /// refreshing its copy of the window. Only the first two are driven by the run loop; the third
    /// is forced here by `demandAFreshSurface()`. Polling for `agreeing` byte-identical captures in
    /// a row then waits out whichever of the first two is slowest on the day.
    ///
    /// `columns` narrows the region stability is judged over to the strip the caller compares;
    /// waiting for a pane it never looks at only costs time. On timeout this returns the last
    /// capture rather than failing, so the caller's own assertion reports the failure with its own
    /// message and its own numbers.
    func capture(
        columns: Range<Int>? = nil, agreeing: Int = 6, ceiling: TimeInterval = 10,
        until satisfied: (Capture) -> Bool = { _ in true }
    ) throws -> Capture {
        let deadline = Date().addingTimeInterval(ceiling)
        var previous: Capture?
        var agreed = 0
        demandAFreshSurface()
        while Date() < deadline {
            pump()
            // A freshly ordered window has no surface at the window server until the run loop has
            // turned, and the first surfaces it does hand back can be flat.
            guard let latest = try shoot(), !latest.isBlank else { continue }
            if let previous,
               previous.diff(latest, columns: columns ?? 0..<latest.width).count == 0 {
                agreed += 1
            } else {
                agreed = 0
            }
            previous = latest
            if agreed >= agreeing && satisfied(latest) { return latest }
        }
        return try XCTUnwrap(previous, "the window server never produced an image for the offscreen window")
    }

    /// Views `List` actually drew, by AppKit class name.
    func viewCount(ofClassNamed name: String) -> Int {
        var n = 0
        var queue: [NSView] = [host]
        while let view = queue.popLast() {
            if String(describing: type(of: view)) == name { n += 1 }
            queue.append(contentsOf: view.subviews)
        }
        return n
    }

    /// Makes the window server throw away its copy of the window and take a new one.
    ///
    /// `CGWindowListCreateImage` reads the window server's copy, not the backing store the run loop
    /// has just drawn into, and for a window that never reaches a display `occlusionState` never
    /// contains `.visible`, so nothing refreshes that copy on a schedule a test can wait for.
    /// Measured on this project: a GRDB write reaches the AppKit view tree in 20-29ms every trial,
    /// while the captured image lagged 100-194ms and in 2 of 6 trials never changed at all across
    /// 6s of pumping. A resize forces a new surface and lands on the very next capture — measured,
    /// the first shot after `setFrame` already comes back at the new width — so widening the window
    /// and putting it back is a refresh this side of the process can actually demand.
    private func demandAFreshSurface() {
        let frame = window.frame
        window.setFrame(NSRect(origin: frame.origin, size: CGSize(width: frame.width + 1, height: frame.height)), display: true)
        pump()
        window.setFrame(frame, display: true)
        pump()
    }

    private func pump() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        window.layoutIfNeeded()
        window.displayIfNeeded()
    }

    private func shoot() throws -> Capture? {
        guard let image = CGWindowListCreateImage(
            .null, .optionIncludingWindow, CGWindowID(window.windowNumber),
            [.boundsIgnoreFraming, .bestResolution]
        ) else { return nil }
        return try Capture(NSBitmapImageRep(cgImage: image))
    }
}

/// An environment whose sidebar footer never draws, so nothing in a captured `MainWindow` changes
/// except what the test writes.
///
/// `AccountUsageFooter` otherwise reads the real `~/.claude.json` on a `.utility` detached task and
/// polls it every 60s. On a loaded machine that read lands at an unpredictable moment, and when it
/// lands between two captures the bars appear at the bottom of the sidebar — a difference the test
/// then attributes to whatever it just wrote. Pointing the model at a path that does not exist
/// keeps `snapshot` nil, and a refresher that always declines keeps it that way.
@MainActor
func renderEnvironment(
    db: AppDatabase, supervisor: (any WorkerSupervising)? = nil,
    router: NotificationRouter? = nil
) -> AppEnvironment {
    AppEnvironment(
        db: db, supervisor: supervisor ?? StubSupervisor(), router: router,
        accountUsage: AccountUsageModel(
            configURL: URL(fileURLWithPath: "/nonexistent/agent-board-render-tests.json"),
            refresher: AccountUsageRefresher { _ in false }
        )
    )
}
