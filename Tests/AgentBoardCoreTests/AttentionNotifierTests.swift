import XCTest
@testable import AgentBoardCore

/// `MacNotifier.post` is inert under `xctest` — `UNUserNotificationCenter.current()` traps unless
/// the process is an app bundle — so what is asserted here is the decision to notify and the text
/// of the banner, never the system call.
final class AttentionNotifierTests: XCTestCase {
    private func project(
        _ causes: [AttentionCause], id: String = "p1", name: String = "Demo"
    ) -> ProjectAttention {
        ProjectAttention(id: id, name: name, causes: causes)
    }

    private let approval = AttentionCause(reason: .pendingApproval, count: 1)
    private let blocked = AttentionCause(reason: .blockedWorker, count: 1, detail: "Add the sidebar")

    func testAPendingApprovalNotifiesAndNamesItsProject() {
        var notifier = AttentionNotifier()

        let raised = notifier.notices(for: [project([approval])])

        XCTAssertEqual(raised.map(\.reason), [.pendingApproval])
        XCTAssertEqual(raised[0].title, "Approval waiting — Demo")
        XCTAssertEqual(raised[0].body, "1 approval waiting.")
        XCTAssertEqual(raised[0].projectId, "p1")
    }

    func testABlockedWorkerNotifiesAndCarriesTheTaskTitle() {
        var notifier = AttentionNotifier()

        let raised = notifier.notices(for: [project([blocked])])

        XCTAssertEqual(raised.map(\.reason), [.blockedWorker])
        XCTAssertEqual(raised[0].title, "Worker blocked — Demo")
        XCTAssertEqual(raised[0].body, "1 worker blocked: Add the sidebar.")
    }

    func testEveryNotifiedProjectIsNamedEvenWhenSeveralNeedTheHuman() {
        var notifier = AttentionNotifier()

        let raised = notifier.notices(for: [
            project([approval], id: "p1", name: "Agent Board"),
            project([blocked], id: "p2", name: "Omaha"),
        ])

        XCTAssertEqual(raised.map(\.title), ["Approval waiting — Agent Board", "Worker blocked — Omaha"])
    }

    func testAPersistingConditionNotifiesOnceNotOnEveryObservation() {
        var notifier = AttentionNotifier()
        let state = [project([approval])]

        XCTAssertEqual(notifier.notices(for: state).count, 1)
        XCTAssertEqual(notifier.notices(for: state), [])
        XCTAssertEqual(notifier.notices(for: state), [])
    }

    /// A second approval arriving while the first is unanswered is a bigger badge, not a new banner.
    func testAGrowingQueueDoesNotNotifyAgain() {
        var notifier = AttentionNotifier()
        _ = notifier.notices(for: [project([approval])])

        let raised = notifier.notices(for: [
            project([AttentionCause(reason: .pendingApproval, count: 3)])
        ])

        XCTAssertEqual(raised, [])
    }

    func testTheSameConditionNotifiesAgainAfterItHasCleared() {
        var notifier = AttentionNotifier()
        _ = notifier.notices(for: [project([approval])])
        XCTAssertEqual(notifier.notices(for: [project([])]), [])

        let raised = notifier.notices(for: [project([approval])])

        XCTAssertEqual(raised.map(\.reason), [.pendingApproval])
    }

    /// One cause clearing must not re-arm the other, which is still unanswered.
    func testClearingOneReasonLeavesTheOtherAnnounced() {
        var notifier = AttentionNotifier()
        _ = notifier.notices(for: [project([approval, blocked])])

        XCTAssertEqual(notifier.notices(for: [project([blocked])]), [])
        XCTAssertEqual(notifier.notices(for: [project([approval, blocked])]).map(\.reason), [.pendingApproval])
    }

    func testAProjectDisappearingClearsItsAnnouncements() {
        var notifier = AttentionNotifier()
        _ = notifier.notices(for: [project([approval])])

        XCTAssertEqual(notifier.notices(for: []), [])
        XCTAssertEqual(notifier.notices(for: [project([approval])]).count, 1)
    }

    func testBothNotifyingReasonsRaiseSeparateBannersInSeverityOrder() {
        var notifier = AttentionNotifier()

        let raised = notifier.notices(for: [project([approval, blocked])])

        XCTAssertEqual(raised.map(\.reason), [.pendingApproval, .blockedWorker])
        XCTAssertEqual(raised.map(\.body), Array(repeating: "1 approval waiting, 1 worker blocked: Add the sidebar.", count: 2))
    }

    /// Stranded reports and an unacknowledged shutdown badge the sidebar without interrupting:
    /// neither stops work the way an unanswered approval or a blocked worker does.
    func testOnlyApprovalsAndBlockedWorkersInterrupt() {
        var notifier = AttentionNotifier()

        let raised = notifier.notices(for: [project([
            AttentionCause(reason: .strandedReports, count: 2),
            AttentionCause(reason: .overdueShutdown, count: 1),
        ])])

        XCTAssertEqual(raised, [])
        XCTAssertEqual(AttentionNotifier.notifying, [.pendingApproval, .blockedWorker])
    }

    func testNothingFiresForTheProjectTheHumanIsLookingAt() {
        var notifier = AttentionNotifier()

        let raised = notifier.notices(for: [
            project([approval], id: "p1", name: "Agent Board"),
            project([blocked], id: "p2", name: "Omaha"),
        ], focused: "p1")

        XCTAssertEqual(raised.map(\.projectId), ["p2"])
    }

    /// The human saw the condition on screen, so it must not resurface as a banner when they move
    /// to another project. Only the condition clearing re-arms it.
    func testASuppressedConditionDoesNotFireOnceFocusMovesAway() {
        var notifier = AttentionNotifier()
        _ = notifier.notices(for: [project([approval])], focused: "p1")

        XCTAssertEqual(notifier.notices(for: [project([approval])], focused: nil), [])
    }

    func testAConditionArrivingAfterFocusMovesAwayStillFires() {
        var notifier = AttentionNotifier()
        _ = notifier.notices(for: [project([approval])], focused: "p1")

        let raised = notifier.notices(for: [project([approval, blocked])], focused: nil)

        XCTAssertEqual(raised.map(\.reason), [.blockedWorker])
    }

    func testABannerWithNoProjectNameFallsBackToTheBareHeadline() {
        XCTAssertEqual(NotificationText.title("Worker may be stuck", project: nil), "Worker may be stuck")
        XCTAssertEqual(NotificationText.title("Worker may be stuck", project: "  "), "Worker may be stuck")
        XCTAssertEqual(
            NotificationText.title("Worker stopped at cap", project: "Omaha"), "Worker stopped at cap — Omaha"
        )
    }

    func testPluralHeadlinesCountWhatIsWaiting() {
        var notifier = AttentionNotifier()

        let raised = notifier.notices(for: [project([
            AttentionCause(reason: .pendingApproval, count: 2),
            AttentionCause(reason: .blockedWorker, count: 3),
        ])])

        XCTAssertEqual(raised.map(\.title), ["2 approvals waiting — Demo", "3 workers blocked — Demo"])
    }
}
