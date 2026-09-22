import AgentBoardCore
import AppKit
import SwiftUI
import XCTest
@testable import AgentBoard

/// Mounts `ProjectSettingsSheet` offscreen to confirm the notification preferences are actually on
/// the screen and bound to the project's stored settings.
///
/// This machine has no display. `Text` draws into a backing layer with no readable string, so the
/// toggle labels and the caption are **not** asserted here — nobody has looked at them. A SwiftUI
/// `Picker` is the exception: it mounts as a real `NSPopUpButton` whose `title` carries the
/// selected option, which is what makes the mute control assertable at all.
@MainActor
final class NotificationPreferencesSheetRenderTests: XCTestCase {
    private func project(_ db: AppDatabase, notifications: NotificationPreferences) throws -> Project {
        let project = try ProjectStore(db).register(
            name: "Demo", repoPath: "/tmp/prefs-\(UUID().uuidString)", baseBranch: "main",
            worktreeRoot: "/tmp/prefs-worktrees", memoryDir: nil
        )
        var settings = project.settings
        settings.notifications = notifications
        try ProjectStore(db).updateSettings(project.id, settings)
        return try XCTUnwrap(try ProjectStore(db).get(project.id))
    }

    private func popUpTitles(_ project: Project, _ db: AppDatabase) -> [String] {
        let host = NSHostingView(
            rootView: ProjectSettingsSheet(project: project, workspaces: [], initialTab: .notifications, onDeleted: {})
                .environment(AppEnvironment(db: db, supervisor: StubSupervisor()))
        )
        NSApplication.shared.setActivationPolicy(.accessory)
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 700, height: 1400),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderBack(nil)
        for _ in 0..<40 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            window.displayIfNeeded()
        }
        var found: [String] = []
        func walk(_ view: NSView) {
            if let popUp = view as? NSPopUpButton, let title = popUp.title as String? {
                found.append(title)
            }
            view.subviews.forEach(walk)
        }
        walk(host)
        return found
    }

    func testTheSheetShowsTheMuteThisProjectIsUnder() throws {
        let db = try AppDatabase.inMemory()
        let muted = try project(db, notifications: NotificationPreferences(mute: .indefinite))

        XCTAssertTrue(
            popUpTitles(muted, db).contains(NotificationMuteChoice.indefinite.title),
            "the mute picker did not show the project's stored mute"
        )
    }

    func testAnUnmutedProjectShowsTheMutePickerOff() throws {
        let db = try AppDatabase.inMemory()
        let loud = try project(db, notifications: NotificationPreferences())

        let titles = popUpTitles(loud, db)
        XCTAssertTrue(titles.contains(NotificationMuteChoice.off.title), "\(titles)")
        XCTAssertFalse(titles.contains(NotificationMuteChoice.indefinite.title), "\(titles)")
    }

    func testATimedMuteShowsItsDuration() throws {
        let db = try AppDatabase.inMemory()
        let hour = try project(
            db, notifications: NotificationPreferences(mute: .until(.nowMillis + 3_000_000))
        )

        XCTAssertTrue(
            popUpTitles(hour, db).contains(NotificationMuteChoice.oneHour.title),
            "the mute picker did not show a live one-hour mute"
        )
    }

    /// The sheet builds one toggle per `NotificationCategory.allCases`, so this pins the labels a
    /// human will read there. A toggle mounts as a `SwiftUIAppKitButton` with no readable label,
    /// so the rendered switches themselves are not assertable on this machine.
    func testTheCategoryLabelsTheSheetBuildsItsSwitchesFrom() {
        XCTAssertEqual(
            NotificationCategory.allCases.map(\.title),
            ["Approvals waiting", "Blocked workers", "Cap breaches and stalls", "Worker failures"]
        )
    }
}
