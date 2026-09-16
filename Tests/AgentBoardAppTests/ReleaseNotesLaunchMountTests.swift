import AgentBoardCore
import AppKit
import SwiftUI
import XCTest

@testable import AgentBoard

/// That the once-after-an-update rule is actually wired to a launch, rather than only correct as a
/// value. `MainWindow` is mounted in an offscreen borderless `NSWindow` over a real in-memory board
/// and its own `UserDefaults` suite, the run loop is pumped, and the suite is read back.
///
/// The record is the observable: this machine has no display, `osascript` is denied assistive
/// access, and a `Window` scene only exists inside a running `App` — so **nobody has seen whether
/// the release-notes window appears**, here or anywhere in this suite. What these prove is that the
/// launch task runs when the board mounts and applies the decision. `HelpMenuTests` is what drives
/// the real binary and counts real windows, and it runs the unbundled `.unavailable` case.
@MainActor
final class ReleaseNotesLaunchMountTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "agentboard-launch-notes-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    @MainActor
    private final class Mount {
        let window: NSWindow
        let host: NSView

        init(db: AppDatabase, announcer: ReleaseNotesAnnouncer) {
            host = NSHostingView(
                rootView: MainWindow().environment(
                    AppEnvironment(db: db, supervisor: StubSupervisor(), releaseNotes: announcer)
                )
            )
            NSApplication.shared.setActivationPolicy(.accessory)
            // Borderless and far offscreen: AppKit drags a `.titled` window back onto a visible
            // screen, and this machine has none.
            window = NSWindow(
                contentRect: NSRect(x: -20_000, y: -20_000, width: 1100, height: 700),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.contentView = host
            window.orderBack(nil)
        }

        func settle(turns: Int = 80) {
            for _ in 0..<turns {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                window.layoutIfNeeded()
                window.displayIfNeeded()
            }
        }

        func close() { window.orderOut(nil) }
    }

    private func version(_ text: String) throws -> ReleaseVersion {
        try XCTUnwrap(ReleaseVersion(text))
    }

    private func state(running: String, versions: [String]) throws -> ReleaseNotesState {
        .loaded(
            ReleaseNotes(
                appVersion: try version(running),
                entries: try versions.map {
                    ReleaseNotesEntry(version: try version($0), body: "Notes for \($0).")
                }
            )
        )
    }

    private func mountAndSettle(_ state: ReleaseNotesState) throws {
        let db = try AppDatabase.inMemory()
        _ = try ProjectStore(db).register(
            name: "Alpha", repoPath: "/tmp/notes-\(UUID().uuidString)", baseBranch: "main",
            worktreeRoot: "/tmp/notes-worktrees", memoryDir: nil
        )
        let mount = Mount(db: db, announcer: ReleaseNotesAnnouncer(state: state, defaults: defaults))
        defer { mount.close() }
        mount.settle()
    }

    private var recorded: String? { defaults.string(forKey: ReleaseNotesAnnouncer.key) }

    /// The control. Mounting the board on a build with no notes must leave the store exactly as it
    /// was — otherwise a write in any later test says only that something ran, not that the
    /// decision reached it.
    func testMountingABoardWithNoNotesWritesNothing() throws {
        try mountAndSettle(.unavailable)
        XCTAssertNil(recorded, "an unbundled build wrote a record from a mount")
    }

    /// The first ever launch, end to end through the view: silent, and the current version recorded
    /// so the next launch is not mistaken for an upgrade.
    func testAFirstLaunchRecordsTheVersionFromTheMount() throws {
        try mountAndSettle(try state(running: "0.1.0", versions: ["0.1.0"]))
        XCTAssertEqual(recorded, "0.1.0", "the launch task did not run when the board mounted")
    }

    /// The upgrade path through the view. `openWindow(id:)` is reached here and has no scene to
    /// open under `xctest`; what this asserts is that the branch is taken and survives, not that a
    /// window appeared.
    func testAnUpgradeTakesTheOpeningBranchAndMovesTheRecord() throws {
        defaults.set("0.1.0", forKey: ReleaseNotesAnnouncer.key)
        try mountAndSettle(try state(running: "0.2.0", versions: ["0.2.0", "0.1.0"]))
        XCTAssertEqual(recorded, "0.2.0")
    }

    /// A second launch at the same version. The record is what makes it quiet, and mounting again
    /// must not disturb it.
    func testASecondLaunchAtTheSameVersionLeavesTheRecordWhereItIs() throws {
        defaults.set("0.2.0", forKey: ReleaseNotesAnnouncer.key)
        try mountAndSettle(try state(running: "0.2.0", versions: ["0.2.0", "0.1.0"]))
        XCTAssertEqual(recorded, "0.2.0")
    }
}
