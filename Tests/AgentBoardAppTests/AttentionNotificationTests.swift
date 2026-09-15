import AgentBoardCore
import Foundation
import XCTest
@testable import AgentBoard

/// The supervisor's end of the notification path: the attention signal it reads from the real
/// database, the project name it puts in every banner, and the focus it suppresses for.
/// `MacNotifier.post` is inert under `xctest` — `UNUserNotificationCenter.current()` traps unless
/// the process is an app bundle — so every assertion here is over what the supervisor decided to
/// post, never over the posting.
@MainActor
final class AttentionNotificationTests: XCTestCase {
    private var fixture: SupervisorFixture!
    private var supervisor: WorkerSupervisor { fixture.supervisor }

    override func setUp() async throws {
        fixture = try SupervisorFixture.make()
        supervisor.isFrontmost = { true }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: fixture.supportDir)
        fixture = nil
    }

    private func pendingApproval() throws {
        try fixture.approvals.create(
            projectId: fixture.project.id, kind: .spawn, taskId: nil, epicId: nil,
            requestedBy: "orchestrator", reason: "spawn a worker"
        )
    }

    @discardableResult
    private func blockedWorker(_ title: String = "Add the sidebar") throws -> BoardTask {
        let task = try fixture.tasks.create(
            projectId: fixture.project.id, title: title, body: nil, acceptance: nil,
            priority: nil, column: .running, origin: .human, epicId: nil
        )
        try fixture.tasks.setBlocked(task.id, true, reason: "need creds")
        return task
    }

    func testAPendingApprovalNotifiesAndNamesTheProject() throws {
        try pendingApproval()

        let raised = supervisor.raiseAttentionBanners()

        XCTAssertEqual(raised.map(\.reason), [.pendingApproval])
        XCTAssertEqual(raised[0].title, "Approval waiting — Demo")
        XCTAssertEqual(raised[0].body, "1 approval waiting.")
    }

    func testABlockedWorkerNotifiesAndNamesTheProject() throws {
        try blockedWorker()

        let raised = supervisor.raiseAttentionBanners()

        XCTAssertEqual(raised.map(\.reason), [.blockedWorker])
        XCTAssertEqual(raised[0].title, "Worker blocked — Demo")
        XCTAssertEqual(raised[0].body, "1 worker blocked: Add the sidebar.")
    }

    func testAQuietProjectNotifiesNothing() {
        XCTAssertEqual(supervisor.raiseAttentionBanners(), [])
    }

    func testAnUnansweredApprovalDoesNotNotifyOnEveryTick() throws {
        try pendingApproval()

        XCTAssertEqual(supervisor.raiseAttentionBanners().count, 1)
        XCTAssertEqual(supervisor.raiseAttentionBanners(), [])
        XCTAssertEqual(supervisor.raiseAttentionBanners(), [])
    }

    func testTheSameConditionNotifiesAgainAfterItIsAnswered() throws {
        let task = try blockedWorker()
        XCTAssertEqual(supervisor.raiseAttentionBanners().count, 1)

        try fixture.tasks.setBlocked(task.id, false, reason: nil)
        XCTAssertEqual(supervisor.raiseAttentionBanners(), [])

        try fixture.tasks.setBlocked(task.id, true, reason: "still stuck")
        XCTAssertEqual(supervisor.raiseAttentionBanners().map(\.reason), [.blockedWorker])
    }

    func testNothingFiresForTheProjectOnScreen() throws {
        try pendingApproval()
        supervisor.focusChanged(projectId: fixture.project.id)

        XCTAssertEqual(supervisor.raiseAttentionBanners(), [])
    }

    /// At a Glance is not "looking at the project": the badge there is easy to miss.
    func testAtAGlanceSuppressesNothing() throws {
        try pendingApproval()
        supervisor.focusChanged(projectId: nil)

        XCTAssertEqual(supervisor.raiseAttentionBanners().count, 1)
    }

    /// A selection left behind another app's window is not something the human can see.
    func testASelectedProjectStillNotifiesWhenAgentBoardIsNotFrontmost() throws {
        try pendingApproval()
        supervisor.focusChanged(projectId: fixture.project.id)
        supervisor.isFrontmost = { false }

        XCTAssertEqual(supervisor.raiseAttentionBanners().count, 1)
    }

    func testTheFourExistingBannersNameTheirProject() {
        for headline in ["Worker never started", "Worker may be stuck", "Worker stopped at cap", "Agent needs input"] {
            XCTAssertEqual(
                supervisor.notificationTitle(headline, projectId: fixture.project.id),
                "\(headline) — Demo"
            )
        }
    }

    func testABannerForAProjectThatNoLongerExistsKeepsItsBareHeadline() {
        XCTAssertEqual(supervisor.notificationTitle("Worker may be stuck", projectId: "gone"), "Worker may be stuck")
    }
}
