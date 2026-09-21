import AgentBoardCore
import AppKit
import SwiftUI
import XCTest
@testable import AgentBoard

/// Regenerates the images a human judges these buttons by, in the same two real contexts and the
/// same two formats the design candidates were rendered in: the 2x shipping raster, and that same
/// raster scaled 8x with interpolation off so it shows the pixels that exist rather than a symbol
/// redrawn larger.
///
/// Inert unless `AGENTBOARD_DESIGN_RENDER_DIR` names a directory to write into — a test suite has
/// no business writing to anyone's Desktop on its own.
///
///     AGENTBOARD_DESIGN_RENDER_DIR=~/Desktop/agentboard-icon-options \
///         swift test --filter SessionActionButtonsDesignRenderTests
@MainActor
final class SessionActionButtonsDesignRenderTests: XCTestCase {
    private var session: AgentSession {
        AgentSession(
            sessionId: "session-1", shortId: "abcdef12", projectId: "p-1", role: .worker,
            worktreePath: "/tmp/worktrees/w1", cwd: "/tmp/repo", state: .running
        )
    }

    /// The tail of a `StatusView` session table row over a `TaskInspectorView` session card — the
    /// two places this pair appears, at the widths they appear at.
    private var sheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 0) {
                Text("2m ago")
                    .frame(width: 110, alignment: .leading)
                HStack(spacing: 4) {
                    SessionActionButtons(session: session, showsTitle: false)
                    Button("Resume") {}
                }
                .controlSize(.small)
                .frame(width: 170, alignment: .leading)
                .clipped()
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("abcdef12").monospaced()
                        Text("running").foregroundStyle(.green)
                        Text("attempt 1").foregroundStyle(.secondary)
                    }
                    Text("$0.42 · 12.3k tok").foregroundStyle(.secondary)
                }
                .font(.caption)
                Spacer()
                Button("Stop") {}
                SessionActionButtons(session: session, showsTitle: true)
            }
            .controlSize(.small)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
            .frame(width: 440)
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func render(dark: Bool) throws -> NSBitmapImageRep {
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 400, height: 140),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: sheet.environment(\.controlActiveState, .active))
        window.contentView = host
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        window.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        for _ in 0..<60 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        return rep
    }

    private func enlarged(_ rep: NSBitmapImageRep, by factor: Int) throws -> NSBitmapImageRep {
        let width = rep.pixelsWide * factor
        let height = rep.pixelsHigh * factor
        let out = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )
        )
        out.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSGraphicsContext.current?.imageInterpolation = .none
        rep.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return out
    }

    func testWriteTheShippedRenders() throws {
        guard let raw = ProcessInfo.processInfo.environment["AGENTBOARD_DESIGN_RENDER_DIR"], !raw.isEmpty else {
            throw XCTSkip("set AGENTBOARD_DESIGN_RENDER_DIR to regenerate the design renders")
        }
        let directory = URL(fileURLWithPath: NSString(string: raw).expandingTildeInPath)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            let appearance = dark ? "dark" : "light"
            let rep = try render(dark: dark)
            for (suffix, image) in [
                ("actual-size", rep), ("enlarged-8x-nearest", try enlarged(rep, by: 8)),
            ] {
                let data = try XCTUnwrap(image.representation(using: .png, properties: [:]))
                let url = directory.appending(path: "6-SHIPPED-two-icons-monochrome--\(appearance)--\(suffix).png")
                try data.write(to: url)
                print("WROTE \(url.path) \(image.pixelsWide)x\(image.pixelsHigh)")
            }
        }
    }
}
