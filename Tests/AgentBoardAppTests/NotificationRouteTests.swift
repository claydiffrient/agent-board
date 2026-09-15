import AgentBoardCore
import XCTest
@testable import AgentBoard

/// The routing decision, asserted as pure logic: given the `userInfo` a banner carries, which
/// project and which screen. Delivery itself is untestable here — `UNUserNotificationCenter
/// .current()` traps unless the process is an app bundle, and `xctest` is not one — so nothing in
/// this file posts, receives or clicks anything.
final class NotificationRouteTests: XCTestCase {
    private func route(_ userInfo: [String: String]) throws -> NotificationRoute {
        try XCTUnwrap(NotificationRoute(userInfo: userInfo))
    }

    func testAnApprovalPayloadOpensTheOrchestrator() throws {
        let decoded = try route(NotificationRoute(projectId: "p-alpha", subject: .approvals).userInfo)
        XCTAssertEqual(decoded.projectId, "p-alpha")
        XCTAssertEqual(decoded.subject, .approvals)
        XCTAssertEqual(decoded.screen, .orchestrator)
    }

    /// The approvals sidebar carries the blocked-task section as well as the pending queue, so a
    /// blocked worker lands on the same screen — with the task it is about still in the payload.
    func testABlockedTaskPayloadKeepsItsTaskIdAndOpensTheOrchestrator() throws {
        let decoded = try route(
            NotificationRoute(projectId: "p-alpha", subject: .blockedTask("t-7")).userInfo
        )
        XCTAssertEqual(decoded.subject, .blockedTask("t-7"))
        XCTAssertEqual(decoded.screen, .orchestrator)
    }

    /// A session that blocked without a task appears in no task card, only the Status roster.
    func testASessionPayloadOpensStatus() throws {
        let decoded = try route(NotificationRoute(projectId: "p-alpha", subject: .session("s-1")).userInfo)
        XCTAssertEqual(decoded.subject, .session("s-1"))
        XCTAssertEqual(decoded.screen, .status)
    }

    func testEveryPayloadRoundTrips() throws {
        let subjects: [NotificationRoute.Subject] = [
            .approvals, .blockedTask("t-1"), .blockedTask(nil), .session("s-1"), .reports,
            .shutdown, .project,
        ]
        for subject in subjects {
            let original = NotificationRoute(projectId: "p-alpha", subject: subject)
            XCTAssertEqual(try route(original.userInfo), original, "\(subject) did not round-trip")
        }
    }

    func testAPayloadWithoutAProjectRoutesNowhere() {
        XCTAssertNil(NotificationRoute(userInfo: [:]))
        XCTAssertNil(NotificationRoute(userInfo: [NotificationRoute.Key.projectId: ""]))
        XCTAssertNil(NotificationRoute(userInfo: [NotificationRoute.Key.subject: "approvals"]))
    }

    /// A banner posted by an older build carries a subject this one has never heard of. Opening its
    /// project is still better than dropping the click.
    func testAnUnknownSubjectStillOpensItsProject() throws {
        let decoded = try route([
            NotificationRoute.Key.projectId: "p-alpha",
            NotificationRoute.Key.subject: "somethingLater",
            NotificationRoute.Key.subjectId: "x",
        ])
        XCTAssertEqual(decoded.projectId, "p-alpha")
        XCTAssertEqual(decoded.subject, .project)
        XCTAssertEqual(decoded.screen, .orchestrator)
    }

    /// A `session` payload that lost its id would otherwise decode to a subject with nothing to
    /// point at; it falls back to the project rather than claiming a session.
    func testASessionPayloadWithoutAnIdFallsBackToTheProject() throws {
        let decoded = try route([
            NotificationRoute.Key.projectId: "p-alpha",
            NotificationRoute.Key.subject: "session",
        ])
        XCTAssertEqual(decoded.subject, .project)
        XCTAssertEqual(decoded.screen, .orchestrator)
    }

    func testEveryAttentionReasonHasASubject() {
        let expected: [AttentionReason: NotificationRoute.Subject] = [
            .pendingApproval: .approvals,
            .blockedWorker: .blockedTask(nil),
            .strandedReports: .reports,
            .overdueShutdown: .shutdown,
        ]
        for reason in AttentionReason.allCases {
            XCTAssertEqual(NotificationRoute.subject(for: reason), expected[reason], "\(reason)")
        }
    }

    /// The banner the supervisor actually raises and the route a click follows must name the same
    /// project — the notice is the only thing the post carries.
    func testARouteBuiltFromANoticeCarriesItsProject() throws {
        let notice = AttentionNotice(
            projectId: "p-beta", reason: .pendingApproval, title: "Approval waiting — Beta",
            body: "1 approval waiting"
        )
        let decoded = try route(NotificationRoute(notice).userInfo)
        XCTAssertEqual(decoded.projectId, "p-beta")
        XCTAssertEqual(decoded.screen, .orchestrator)
    }
}

/// The notifier's three decisions, as values. The centre itself is unreachable under `xctest`, so
/// `granted`, `denied` and `failed` can only be exercised this way.
@MainActor
final class NotificationAuthorizationTests: XCTestCase {
    func testTheTestRunnerIsNotAnAppBundle() {
        XCTAssertFalse(
            MacNotifier.isAppBundle,
            "the guard that keeps UNUserNotificationCenter.current() from trapping has stopped holding"
        )
        XCTAssertEqual(MacNotifier().authorization, .unavailable)
    }

    /// Posting and starting under `xctest` must both fall through. If the guard broke, this traps
    /// rather than failing.
    func testPostingAndStartingAreInertWithoutAnAppBundle() {
        let notifier = MacNotifier()
        let router = NotificationRouter()
        notifier.start(router: router)
        notifier.post(title: "Approval waiting", body: "1 approval waiting")
        notifier.post(
            title: "Worker blocked", body: "needs input",
            route: NotificationRoute(projectId: "p-alpha", subject: .blockedTask("t-1"))
        )
        XCTAssertEqual(notifier.authorization, .unavailable)
        XCTAssertNil(router.route)
        XCTAssertEqual(router.sequence, 0)
    }

    func testAuthorizationIsRequestedOnlyBeforeAnAnswerArrives() {
        XCTAssertTrue(MacNotifier.shouldRequest(.notAsked))
        for answered: MacNotifier.Authorization in [.granted, .denied, .failed("boom"), .unavailable] {
            XCTAssertFalse(MacNotifier.shouldRequest(answered), "\(answered) would re-prompt")
        }
    }

    /// A denial must cost an early return, not a request and a dropped post, every time a signal
    /// fires.
    func testOnlyAGrantedAnswerPosts() {
        XCTAssertTrue(MacNotifier.canPost(.granted))
        for refused: MacNotifier.Authorization in [.notAsked, .denied, .failed("boom"), .unavailable] {
            XCTAssertFalse(MacNotifier.canPost(refused), "\(refused) must not post")
        }
    }

    func testTheCallbackAnswerIsRemembered() {
        XCTAssertEqual(MacNotifier.outcome(granted: true, error: nil), .granted)
        XCTAssertEqual(MacNotifier.outcome(granted: false, error: nil), .denied)
        XCTAssertEqual(
            MacNotifier.outcome(granted: true, error: CocoaError(.fileNoSuchFile)),
            .failed(CocoaError(.fileNoSuchFile).localizedDescription)
        )
    }

    /// The window says notifications are off only when the user can do something about it.
    func testOnlyAnActionableRefusalIsAnnounced() {
        XCTAssertNotNil(MacNotifier.offMessage(.denied))
        XCTAssertNotNil(MacNotifier.offMessage(.failed("boom")))
        for quiet: MacNotifier.Authorization in [.granted, .notAsked, .unavailable] {
            XCTAssertNil(MacNotifier.offMessage(quiet), "\(quiet) should say nothing")
        }
    }
}

@MainActor
final class NotificationRouterTests: XCTestCase {
    func testClickingTheSameBannerTwiceRoutesTwice() {
        let router = NotificationRouter()
        let route = NotificationRoute(projectId: "p-alpha", subject: .approvals)
        XCTAssertEqual(router.sequence, 0)
        router.open(route)
        XCTAssertEqual(router.route, route)
        XCTAssertEqual(router.sequence, 1)
        router.open(route)
        XCTAssertEqual(router.sequence, 2, "an identical second click must be a second route")
    }
}
