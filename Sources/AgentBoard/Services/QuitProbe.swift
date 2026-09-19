import AppKit
import Foundation
import SwiftUI

@Observable
@MainActor
private final class ProbeSheetState {
    static let shared = ProbeSheetState()
    var presented = true
}

private struct ProbeSheetHost: View {
    @State private var state = ProbeSheetState.shared

    var body: some View {
        Color.clear.sheet(
            isPresented: Binding(get: { state.presented }, set: { state.presented = $0 })
        ) {
            Text("probe sheet").frame(width: 400, height: 300)
        }
    }
}

/// Env-gated diagnostic that asks the real application to quit under an arrangement of windows and
/// reports whether it did. Termination belongs to the assembled app, not to any view, so an
/// offscreen mount cannot answer it and there is no display here to look at. `AGENTBOARD_E2E_REPO`
/// is the same shape: product code behind an environment variable that nothing in the UI reaches.
///
/// A run that terminated writes nothing and exits 0. A run that survived its own `terminate` writes
/// the report and exits 3. `QuitProbeTests` reads the exit status. It waits with `Task.sleep` and
/// never pumps `RunLoop.main` itself: pumping from inside the launch sequence starves it, and the
/// window this waits for then never arrives.
@MainActor
enum QuitProbe {
    static let outputKey = "AGENTBOARD_QUIT_PROBE"
    /// What to put on screen before quitting: `none`, `sheet` (an AppKit sheet attached to the app
    /// window, which is where the quit button lives), `window` (a second ordinary window), `ended`
    /// (a sheet attached and then ended), `swiftui` (a SwiftUI sheet ended behind its binding's
    /// back), `swiftui-dismiss` (a SwiftUI sheet dismissed through its binding) or `appquit` (a
    /// SwiftUI sheet quit the way `GlobalShutdownSheet` does, through the real `AppQuit`).
    static let modeKey = "AGENTBOARD_QUIT_PROBE_MODE"

    static func runIfRequested() {
        guard let path = ProcessInfo.processInfo.environment[outputKey] else { return }
        let mode = ProcessInfo.processInfo.environment[modeKey] ?? "none"
        _Concurrency.Task { @MainActor in
            guard let host = await waitForWindow() else {
                write(["error": "no window appeared", "windows": NSApp.windows.count], to: path)
                exit(2)
            }
            var report: [String: Any] = [
                "mode": mode,
                "delegate": NSApp.delegate.map { String(describing: type(of: $0)) } ?? "",
                "isRunning": NSApp.isRunning,
            ]
            await arrange(mode, host: host, report: &report)
            if mode == "appquit" {
                let quitter = AppQuit()
                // What the quit button does: dismiss the sheet, then ask the app to go.
                ProbeSheetState.shared.presented = false
                quitter.requestQuit()
                try? await _Concurrency.Task.sleep(for: .seconds(5))
                report["survivedTerminate"] = true
                report["quitRefusal"] = quitter.refusal ?? ""
                write(report, to: path)
                exit(3)
            }

            report["windows"] = NSApp.windows.count
            report["attachedSheets"] = NSApp.windows.filter { $0.attachedSheet != nil }.count
            report["respondsToShouldTerminate"] =
                NSApp.delegate?.responds(to: #selector(NSApplicationDelegate.applicationShouldTerminate(_:))) ?? false

            var willTerminate = false
            let token = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: nil
            ) { _ in willTerminate = true }

            NSApplication.shared.terminate(nil)
            try? await _Concurrency.Task.sleep(for: .seconds(3))
            NotificationCenter.default.removeObserver(token)

            report["survivedTerminate"] = true
            report["willTerminateFired"] = willTerminate
            write(report, to: path)
            exit(3)
        }
    }

    private static func arrange(_ mode: String, host: NSWindow, report: inout [String: Any]) async {
        switch mode {
        case "sheet":
            await attachSheet(to: host)
        case "ended":
            let sheet = await attachSheet(to: host)
            host.endSheet(sheet)
            await settle(while: { host.attachedSheet != nil })
        case "window":
            probeWindow(titled: "Quit Probe Window").orderFront(nil)
        case "swiftui", "swiftui-dismiss", "appquit":
            let hosted = probeWindow(titled: "SwiftUI Host")
            hosted.contentView = NSHostingView(rootView: ProbeSheetHost())
            hosted.orderFront(nil)
            await settle(while: { hosted.attachedSheet == nil })
            report["swiftuiSheetAttached"] = hosted.attachedSheet != nil
            if mode == "appquit" {
                return
            }
            if mode == "swiftui-dismiss" {
                ProbeSheetState.shared.presented = false
                await settle(while: { hosted.attachedSheet != nil })
            } else if let sheet = hosted.attachedSheet {
                hosted.endSheet(sheet)
                await settle(while: { hosted.attachedSheet == nil })
            }
            report["swiftuiSheetAfterEndSheet"] = hosted.attachedSheet != nil
        default:
            break
        }
        try? await _Concurrency.Task.sleep(for: .milliseconds(500))
    }

    @discardableResult
    private static func attachSheet(to host: NSWindow) async -> NSWindow {
        let sheet = probeWindow(titled: "Quit Probe Sheet")
        host.beginSheet(sheet, completionHandler: nil)
        await settle(while: { host.attachedSheet == nil })
        return sheet
    }

    private static func probeWindow(titled title: String) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 620, height: 520),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.title = title
        return window
    }

    private static func waitForWindow() async -> NSWindow? {
        for _ in 0..<600 {
            if let window = NSApp.windows.first(where: { $0.contentView != nil }) { return window }
            try? await _Concurrency.Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    private static func settle(while pending: () -> Bool, turns: Int = 40) async {
        for _ in 0..<turns where pending() {
            try? await _Concurrency.Task.sleep(for: .milliseconds(50))
        }
    }

    private static func write(_ report: [String: Any], to path: String) {
        let data = (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]))
            ?? Data("{}".utf8)
        try? data.write(to: URL(fileURLWithPath: path))
    }
}
