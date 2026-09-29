import Foundation
import XCTest
@testable import AgentBoard

/// Why `GlobalShutdownSheet` dismisses before it quits, measured rather than reasoned about.
///
/// Termination belongs to the assembled application, so no offscreen mount can answer it: these run
/// the shipped `AgentBoard` binary with `AGENTBOARD_QUIT_PROBE` set and read the exit status. A run
/// that terminated wrote no report and exits 0; a run that survived its own `terminate` writes the
/// report and exits 3. Each launch gets its own support directory and database so it never opens
/// the developer's real board.
final class QuitProbeTests: XCTestCase {
    func testTerminateEndsTheAppWhenNoSheetIsAttached() throws {
        let run = try probe(mode: "none")
        XCTAssertEqual(run.status, 0, "the app did not quit with nothing in the way")
        XCTAssertNil(run.report, "a report means the process outlived its own terminate")
    }

    /// The defect: the quit button lives in a sheet, and a sheet is exactly what stops this.
    func testTerminateIsRefusedSilentlyWhileASheetIsAttached() throws {
        let run = try probe(mode: "sheet")
        XCTAssertEqual(run.status, 3, "the app quit with a sheet attached")
        XCTAssertEqual(run.report?["survivedTerminate"] as? Bool, true)
        XCTAssertEqual(
            run.report?["willTerminateFired"] as? Bool, false,
            "termination got far enough to post willTerminate, so the sheet is not what stopped it"
        )
        // `respondsToShouldTerminate` itself is no longer a stable cross-OS signal: on macOS 27,
        // `NSApp.delegate` (reported here as `delegate == "AppDelegate"`, SwiftUI's own synthesized
        // default) answers `applicationShouldTerminate(_:)` even though this target defines neither
        // an `AppDelegate` nor that method; on macOS 26 (CI's runner) it does not. Asserting either
        // boolean here would tie this test to whichever OS wrote it. What's actually in scope for
        // "this refusal may be ours" is answered instead below, by scanning this target's own
        // sources rather than reading a platform-supplied delegate's behavior.
        XCTAssertEqual(
            Self.filesDefining("func applicationShouldTerminate"), [],
            "this target now implements applicationShouldTerminate itself — the sheet refusal above may be ours, not the platform's"
        )
    }

    /// Enumerates `Sources/**/*.swift` for files containing `needle`, the way
    /// `MessagePTYIsolationTests` proves the PTY-write invariant from source rather than behavior.
    private static func filesDefining(_ needle: String) -> [String] {
        let sourcesRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // AgentBoardAppTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Sources")
        guard let enumerator = FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil)
        else { return [] }
        var matches: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            if let text = try? String(contentsOf: url, encoding: .utf8), text.contains(needle) {
                matches.append(url.lastPathComponent)
            }
        }
        return matches
    }

    func testASecondOrdinaryWindowDoesNotStopTermination() throws {
        XCTAssertEqual(try probe(mode: "window").status, 0, "a plain second window blocked the quit")
    }

    func testDismissingTheSheetRestoresTermination() throws {
        XCTAssertEqual(try probe(mode: "ended").status, 0, "the app would not quit after its sheet ended")
    }

    /// Ending a SwiftUI sheet behind SwiftUI's back does not work: the binding is still true, so it
    /// re-attaches and the refusal stands. Dismissing it through the binding — which is what
    /// `dismiss()` does in `GlobalShutdownSheet` — is what actually clears the way.
    func testASwiftUISheetMustBeDismissedThroughItsBinding() throws {
        let behindItsBack = try probe(mode: "swiftui")
        XCTAssertEqual(behindItsBack.status, 3)
        XCTAssertEqual(behindItsBack.report?["swiftuiSheetAttached"] as? Bool, true)
        XCTAssertEqual(
            behindItsBack.report?["swiftuiSheetAfterEndSheet"] as? Bool, true,
            "endSheet cleared a SwiftUI sheet whose binding was still true"
        )

        XCTAssertEqual(
            try probe(mode: "swiftui-dismiss").status, 0,
            "the app would not quit after its SwiftUI sheet was dismissed through the binding"
        )
    }

    /// The acceptance case, end to end in the real application: a quit asked for from inside a
    /// live SwiftUI sheet, through the real `AppQuit`, ends the process. Its opposite is
    /// `testTerminateIsRefusedSilentlyWhileASheetIsAttached` — the same app, the same sheet, and
    /// `NSApplication.terminate` on its own.
    func testQuittingFromInsideASheetThroughAppQuitEndsTheApp() throws {
        let run = try probe(mode: "appquit")
        XCTAssertEqual(
            run.status, 0,
            "the app outlived a quit asked for the way the shutdown sheet asks for it: "
                + "\(run.report?["quitRefusal"] as? String ?? "no refusal recorded")"
        )
    }

    private struct ProbeRun {
        var status: Int32
        var report: [String: Any]?
    }

    private func probe(mode: String) throws -> ProbeRun {
        let executable = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("AgentBoard")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw XCTSkip("AgentBoard is not built beside the test bundle")
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quit-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let report = dir.appendingPathComponent("report.json")

        let process = Process()
        process.executableURL = executable
        process.environment = [
            QuitProbe.outputKey: report.path,
            QuitProbe.modeKey: mode,
            "AGENTBOARD_SUPPORT_DIR": dir.appendingPathComponent("support").path,
            "AGENTBOARD_DB": dir.appendingPathComponent("board.sqlite").path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        let json = (try? Data(contentsOf: report))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return ProbeRun(status: process.terminationStatus, report: json)
    }
}
