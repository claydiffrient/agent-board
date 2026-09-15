import Foundation
import XCTest
@testable import AgentBoardCore

final class NotificationPreferencesTests: XCTestCase {
    private let now: Int64 = 1_700_000_000_000

    func testEveryCategoryDefaultsToNotifying() {
        let prefs = NotificationPreferences()

        XCTAssertEqual(NotificationCategory.allCases.count, 4)
        for category in NotificationCategory.allCases {
            XCTAssertTrue(prefs.allows(category, now: now), category.rawValue)
        }
        XCTAssertFalse(prefs.isMuted(now: now))
    }

    func testTurningOneCategoryOffLeavesTheOthersAlone() {
        var prefs = NotificationPreferences()
        prefs.setEnabled(.capsAndStalls, false)

        XCTAssertFalse(prefs.allows(.capsAndStalls, now: now))
        XCTAssertTrue(prefs.allows(.approvals, now: now))
        XCTAssertTrue(prefs.allows(.blockedWorkers, now: now))
        XCTAssertTrue(prefs.allows(.workerFailures, now: now))
    }

    func testAMuteSilencesEveryCategoryAtOnce() {
        var prefs = NotificationPreferences()
        prefs.mute = .indefinite

        for category in NotificationCategory.allCases {
            XCTAssertFalse(prefs.allows(category, now: now), category.rawValue)
            XCTAssertTrue(prefs.isEnabled(category), "the switch itself is untouched")
        }
    }

    func testATimedMuteEndsOnItsOwn() {
        var prefs = NotificationPreferences()
        prefs.mute = .until(now + 3_600_000)

        XCTAssertFalse(prefs.allows(.approvals, now: now))
        XCTAssertFalse(prefs.allows(.approvals, now: now + 3_599_999))
        XCTAssertTrue(prefs.allows(.approvals, now: now + 3_600_000))
        XCTAssertTrue(prefs.allows(.approvals, now: now + 7_200_000))
    }

    func testPreferencesRoundTripThroughProjectSettings() {
        var settings = ProjectSettings()
        settings.notifications.setEnabled(.approvals, false)
        settings.notifications.setEnabled(.workerFailures, false)
        settings.notifications.mute = .until(now + 60_000)

        let decoded = ProjectSettings.decode(settings.encoded())

        XCTAssertEqual(decoded.notifications, settings.notifications)
        XCTAssertEqual(decoded.notifications.mute, .until(now + 60_000))
        XCTAssertFalse(decoded.notifications.approvals)
        XCTAssertTrue(decoded.notifications.blockedWorkers)
    }

    func testAnIndefiniteMuteRoundTrips() {
        var settings = ProjectSettings()
        settings.notifications.mute = .indefinite

        XCTAssertEqual(ProjectSettings.decode(settings.encoded()).notifications.mute, .indefinite)
    }

    func testEveryBanneringReasonHasACategoryAndTheOthersDoNot() {
        XCTAssertEqual(AttentionReason.pendingApproval.notificationCategory, .approvals)
        XCTAssertEqual(AttentionReason.blockedWorker.notificationCategory, .blockedWorkers)
        XCTAssertNil(AttentionReason.strandedReports.notificationCategory)
        XCTAssertNil(AttentionReason.overdueShutdown.notificationCategory)

        for reason in AttentionNotifier.notifying {
            XCTAssertNotNil(reason.notificationCategory, reason.rawValue)
        }
    }
}

/// The sheet's mute picker maps onto `NotificationMute` and back.
final class NotificationMuteChoiceTests: XCTestCase {
    private let now: Int64 = 1_700_000_000_000

    func testAnUnmutedProjectShowsNotMuted() {
        XCTAssertEqual(NotificationMuteChoice(.none, now: now), .off)
    }

    func testAnExpiredTimedMuteReadsAsNotMuted() {
        XCTAssertEqual(NotificationMuteChoice(.until(now - 1), now: now), .off)
    }

    func testALiveTimedMuteReadsBackAsItsBucket() {
        XCTAssertEqual(NotificationMuteChoice(.until(now + 3_600_000), now: now), .oneHour)
        XCTAssertEqual(NotificationMuteChoice(.until(now + 3_600_001), now: now), .fourHours)
        XCTAssertEqual(NotificationMuteChoice(.indefinite, now: now), .indefinite)
    }

    func testChoosingADurationSetsADeadlineFromNow() {
        XCTAssertEqual(NotificationMuteChoice.oneHour.mute(now: now), .until(now + 3_600_000))
        XCTAssertEqual(NotificationMuteChoice.fourHours.mute(now: now), .until(now + 14_400_000))
        XCTAssertEqual(NotificationMuteChoice.indefinite.mute(now: now), .indefinite)
        XCTAssertEqual(NotificationMuteChoice.off.mute(now: now), NotificationMute.none)
    }

    /// Saving the sheet for an unrelated reason must not hand the human back a fresh hour.
    func testSavingAnUnchangedTimedMuteKeepsItsOriginalDeadline() {
        let running = NotificationMute.until(now + 1_000_000)

        let saved = NotificationMuteChoice(running, now: now).mute(now: now, existing: running)

        XCTAssertEqual(saved, running)
    }

    func testChangingTheDurationRestartsTheClock() {
        let running = NotificationMute.until(now + 1_000_000)
        XCTAssertEqual(NotificationMuteChoice(running, now: now), .oneHour)

        XCTAssertEqual(
            NotificationMuteChoice.fourHours.mute(now: now, existing: running),
            .until(now + 14_400_000)
        )
        XCTAssertEqual(NotificationMuteChoice.off.mute(now: now, existing: running), NotificationMute.none)
    }
}

/// The gating decision for the attention-driven banners, asserted without a database or a
/// `UNUserNotificationCenter`.
final class AttentionNotifierPreferenceTests: XCTestCase {
    private let now: Int64 = 1_700_000_000_000

    private func project(_ id: String, _ causes: [AttentionCause]) -> ProjectAttention {
        ProjectAttention(id: id, name: "Demo", causes: causes)
    }

    private var approvalWaiting: ProjectAttention {
        project("p", [AttentionCause(reason: .pendingApproval, count: 1)])
    }

    func testADisabledCategorySuppressesItsBanner() {
        var prefs = NotificationPreferences()
        prefs.setEnabled(.approvals, false)
        var notifier = AttentionNotifier()

        let raised = notifier.notices(for: [approvalWaiting], now: now, preferences: { _ in prefs })

        XCTAssertEqual(raised, [])
    }

    /// Muting is not hiding: the store's answer is what the sidebar badge reads, and gating the
    /// banner leaves it exactly as it was.
    func testTheAttentionSignalItselfIsUntouchedByAPreference() {
        var prefs = NotificationPreferences()
        prefs.mute = .indefinite
        var notifier = AttentionNotifier()
        let attention = approvalWaiting

        XCTAssertEqual(notifier.notices(for: [attention], now: now, preferences: { _ in prefs }), [])

        XCTAssertTrue(attention.needsAttention)
        XCTAssertEqual(attention.badgeCount, 1)
        XCTAssertEqual(attention.summary, "1 approval waiting.")
        XCTAssertTrue(attention.has(.pendingApproval))
    }

    func testDisablingOneCategoryLeavesTheOtherBannering() {
        var prefs = NotificationPreferences()
        prefs.setEnabled(.approvals, false)
        var notifier = AttentionNotifier()
        let both = project("p", [
            AttentionCause(reason: .pendingApproval, count: 1),
            AttentionCause(reason: .blockedWorker, count: 1, detail: "Add the sidebar"),
        ])

        let raised = notifier.notices(for: [both], now: now, preferences: { _ in prefs })

        XCTAssertEqual(raised.map(\.reason), [.blockedWorker])
    }

    func testOneProjectsPreferencesDoNotSilenceAnother() {
        var quiet = NotificationPreferences()
        quiet.mute = .indefinite
        var notifier = AttentionNotifier()
        let projects = [
            project("muted", [AttentionCause(reason: .pendingApproval, count: 1)]),
            project("loud", [AttentionCause(reason: .pendingApproval, count: 1)]),
        ]

        let raised = notifier.notices(
            for: projects, now: now,
            preferences: { $0 == "muted" ? quiet : NotificationPreferences() }
        )

        XCTAssertEqual(raised.map(\.projectId), ["loud"])
    }

    /// A condition that was never shown is not "already announced": turning the switch back on
    /// while the approval still stands has to raise it.
    func testReEnablingACategoryRaisesTheConditionThatWasSuppressed() {
        var prefs = NotificationPreferences()
        prefs.setEnabled(.approvals, false)
        var notifier = AttentionNotifier()

        XCTAssertEqual(notifier.notices(for: [approvalWaiting], now: now, preferences: { _ in prefs }), [])

        prefs.setEnabled(.approvals, true)
        let raised = notifier.notices(for: [approvalWaiting], now: now, preferences: { _ in prefs })

        XCTAssertEqual(raised.map(\.reason), [.pendingApproval])
    }

    func testATimedMuteLetsTheBannerThroughOnceItExpires() {
        var prefs = NotificationPreferences()
        prefs.mute = .until(now + 3_600_000)
        var notifier = AttentionNotifier()

        XCTAssertEqual(notifier.notices(for: [approvalWaiting], now: now, preferences: { _ in prefs }), [])

        let raised = notifier.notices(
            for: [approvalWaiting], now: now + 3_600_000, preferences: { _ in prefs }
        )

        XCTAssertEqual(raised.map(\.reason), [.pendingApproval])
    }

    func testTheDefaultPreferencesNotifyForEverythingTheNotifierRaises() {
        var notifier = AttentionNotifier()

        let raised = notifier.notices(for: [approvalWaiting], now: now)

        XCTAssertEqual(raised.map(\.reason), [.pendingApproval])
    }
}
