import AgentBoardCore
import SwiftUI
import XCTest
@testable import AgentBoard

/// Confirms `ProjectSettingsSheet` seeds its mute picker from the project's stored notification
/// preferences.
///
/// On macOS 27, in this offscreen/non-active session, a SwiftUI `Picker` no longer constructs an
/// `NSPopUpButton` at all — not renamed, not empty, just absent from the AppKit view tree, even
/// mounted through a real, on-screen, `makeKeyAndOrderFront`-ed window (see the headless UI
/// verification note). So `_muteChoice`'s seeded value is read directly off the constructed
/// `ProjectSettingsSheet` through `Mirror`, rather than off a rendered control. `State.wrappedValue`
/// is a public getter; only reaching the private `_muteChoice` field needs reflection, and `State`'s
/// storage holds the `init(initialValue:)` value synchronously, before any SwiftUI engine touches
/// it — mounting is not needed to read it. What this can no longer prove: that the sheet actually
/// renders an interactive picker bound to this state, or how many pickers a tab shows.
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

    private func seededMuteChoice(_ project: Project) -> NotificationMuteChoice? {
        let sheet = ProjectSettingsSheet(project: project, workspaces: [], initialTab: .notifications, onDeleted: {})
        return seededState(sheet, "_muteChoice")
    }

    func testTheSheetShowsTheMuteThisProjectIsUnder() throws {
        let db = try AppDatabase.inMemory()
        let muted = try project(db, notifications: NotificationPreferences(mute: .indefinite))

        XCTAssertEqual(
            seededMuteChoice(muted), .indefinite,
            "the mute picker's seeded state did not carry the project's stored mute"
        )
    }

    func testAnUnmutedProjectShowsTheMutePickerOff() throws {
        let db = try AppDatabase.inMemory()
        let loud = try project(db, notifications: NotificationPreferences())

        XCTAssertEqual(seededMuteChoice(loud), .off)
    }

    func testATimedMuteShowsItsDuration() throws {
        let db = try AppDatabase.inMemory()
        let hour = try project(
            db, notifications: NotificationPreferences(mute: .until(.nowMillis + 3_000_000))
        )

        XCTAssertEqual(
            seededMuteChoice(hour), .oneHour,
            "the mute picker's seeded state did not carry a live one-hour mute"
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
