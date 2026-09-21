import AgentBoardRuntime
import Foundation
import XCTest
@testable import AgentBoard

/// The Help menu as the shipped app actually builds it.
///
/// A menu bar belongs to a running `NSApplication`, and the xctest runner never builds one — so this
/// launches the real `AgentBoard` binary with `MenuProbe`'s environment variables, which make it
/// write its menu to JSON, fire the Help item twice, list its windows and exit. `osascript` is
/// denied assistive access on this machine, so there is no route to another process's menu bar.
///
/// The launched binary is not an `.app`, so `ReleaseNotesLoader.load()` returns `.unavailable`.
/// That makes this run the no-notes case as well: the item is there anyway, and it opens a window.
final class HelpMenuTests: XCTestCase {
    private struct Probe {
        let help: [[String: Any]]
        let windowsAfterOne: [[String: Any]]
        let windowsAfterTwo: [[String: Any]]

        func helpTitles() -> [String] { help.compactMap { $0["title"] as? String } }
        func helpActions() -> [String] { help.compactMap { $0["action"] as? String } }
        func windowCount(_ title: String, after invocations: Int) -> Int {
            let windows = invocations == 1 ? windowsAfterOne : windowsAfterTwo
            return windows.filter { $0["title"] as? String == title }.count
        }
    }

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("help-menu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testTheHelpMenuCarriesTheWhatsNewItem() throws {
        let probe = try probeApp()
        XCTAssertEqual(probe.helpTitles().last, ReleaseNotesScene.title, "\(probe.helpTitles())")
        let item = try XCTUnwrap(probe.help.first { $0["title"] as? String == ReleaseNotesScene.title })
        XCTAssertEqual(item["action"] as? String, "menuAction:", "the item is in the menu but wired to nothing")
        XCTAssertEqual(item["separator"] as? Bool, false)
    }

    /// `CommandGroup(replacing: .help)` would have deleted both of these. The `.help` group holds
    /// more than the help-book item in this app — SwiftUI files "Toggle Sidebar" and its ⌃⌘S here,
    /// because the View menu is empty — so `after:` is what keeps the shortcut working.
    func testTheDefaultHelpMenuContentsSurvive() throws {
        let probe = try probeApp()
        XCTAssertTrue(probe.helpActions().contains("showHelp:"), "\(probe.helpTitles())")
        XCTAssertTrue(probe.helpActions().contains("toggleSidebar:"), "\(probe.helpTitles())")
    }

    /// `Window` rather than `WindowGroup`: firing the menu item a second time must bring the window
    /// forward, not stack another copy.
    func testOpeningItTwiceLeavesOneWindow() throws {
        let probe = try probeApp(invoking: ReleaseNotesScene.title)
        XCTAssertEqual(probe.windowCount(ReleaseNotesScene.title, after: 1), 1)
        XCTAssertEqual(probe.windowCount(ReleaseNotesScene.title, after: 2), 1)
    }

    /// The unbundled binary is the `.unavailable` state. The decision this task made is that the
    /// item is present and opens a window that explains itself, rather than being hidden or greyed
    /// out — so the window has to actually appear on a build that ships no notes.
    func testABuildWithNoNotesStillOpensTheWindow() throws {
        let probe = try probeApp(invoking: ReleaseNotesScene.title)
        XCTAssertTrue(probe.helpTitles().contains(ReleaseNotesScene.title))
        XCTAssertEqual(probe.windowCount(ReleaseNotesScene.title, after: 1), 1)
    }

    // MARK: driving the app

    private func probeApp(invoking item: String? = nil) throws -> Probe {
        let binary = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("AgentBoard")
        guard FileManager.default.fileExists(atPath: binary.path) else {
            throw XCTSkip("the AgentBoard executable is not beside the test bundle at \(binary.path)")
        }
        let output = scratch.appendingPathComponent("menu-\(UUID().uuidString).json")
        var environment = ProcessInfo.processInfo.environment
        environment[SupportPaths.supportDirEnvKey] = scratch.path
        environment["AGENTBOARD_DB"] = scratch.appendingPathComponent("board.sqlite").path
        environment[MenuProbe.outputKey] = output.path
        if let item { environment[MenuProbe.invokeKey] = item }

        let process = Process()
        process.executableURL = binary
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(120)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning {
            process.terminate()
            XCTFail("the app did not write its menu within 120s")
        }
        XCTAssertEqual(process.terminationStatus, 0, "MenuProbe exited \(process.terminationStatus)")

        let data = try Data(contentsOf: output)
        let report = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any], "unreadable probe output"
        )
        return Probe(
            help: report["help"] as? [[String: Any]] ?? [],
            windowsAfterOne: report["windowsAfterOne"] as? [[String: Any]] ?? [],
            windowsAfterTwo: report["windowsAfterTwo"] as? [[String: Any]] ?? []
        )
    }
}
