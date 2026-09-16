import AgentBoardCore
import Foundation
import XCTest
@testable import AgentBoard

/// Two separate pieces of work landed on the same `post` path: the per-project notification
/// categories that decide whether a banner is raised at all, and the `NotificationRoute` that
/// decides where a click on it lands. Every test here asserts one banner carries both, so a
/// resolution that kept only one side fails rather than merging quietly.
@MainActor
final class NotificationGateAndRouteTests: XCTestCase {
    private struct Banner: Equatable {
        var title: String
        var body: String
        var route: NotificationRoute?
    }

    private var fixture: SupervisorFixture!
    private var supervisor: WorkerSupervisor { fixture.supervisor }
    private var posted: [Banner] = []

    override func setUp() async throws {
        fixture = try SupervisorFixture.make()
        posted = []
        supervisor.isFrontmost = { true }
        supervisor.postBanner = { [weak self] title, body, route in
            self?.posted.append(Banner(title: title, body: body, route: route))
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: fixture.supportDir)
        fixture = nil
    }

    private func setPreferences(_ change: (inout NotificationPreferences) -> Void) throws {
        var settings = fixture.project.settings
        change(&settings.notifications)
        try ProjectStore(fixture.db).updateSettings(fixture.project.id, settings)
    }

    private func pendingApproval() throws {
        try fixture.approvals.create(
            projectId: fixture.project.id, kind: .spawn, taskId: nil, epicId: nil,
            requestedBy: "orchestrator", reason: "spawn a worker"
        )
    }

    private func needsInput(session: String? = "sess-1") async {
        await supervisor.notify(
            projectId: fixture.project.id, sessionId: session,
            title: "Agent needs input", body: "waiting on creds"
        )
    }

    // MARK: - The `post` path

    func testABlockedWorkerBannerIsGatedByItsCategoryAndCarriesItsRoute() async throws {
        await needsInput()

        XCTAssertEqual(posted.count, 1)
        XCTAssertEqual(posted.first?.title, "Agent needs input — Demo")
        XCTAssertEqual(
            posted.first?.route,
            NotificationRoute(projectId: fixture.project.id, subject: .session("sess-1"))
        )

        posted = []
        try setPreferences { $0.setEnabled(.blockedWorkers, false) }
        await needsInput()

        XCTAssertEqual(posted, [], "the category gate has to hold on the routed overload too")
    }

    func testABannerWithNoSessionStillRoutesToItsProject() async throws {
        await needsInput(session: nil)

        XCTAssertEqual(
            posted.first?.route, NotificationRoute(projectId: fixture.project.id, subject: .project)
        )
    }

    func testAMutedProjectPostsNothingThroughThePostPath() async throws {
        try setPreferences { $0.mute = .indefinite }

        await needsInput()

        XCTAssertEqual(posted, [])
    }

    // MARK: - The attention path

    func testAnApprovalBannerIsGatedByItsCategoryAndCarriesItsRoute() throws {
        try pendingApproval()

        XCTAssertEqual(supervisor.raiseAttentionBanners().map(\.reason), [.pendingApproval])
        XCTAssertEqual(
            posted.map(\.route),
            [NotificationRoute(projectId: fixture.project.id, subject: .approvals)]
        )
    }

    func testTurningApprovalsOffDropsTheBannerAndTheRouteItWouldHaveCarried() throws {
        try setPreferences { $0.setEnabled(.approvals, false) }
        try pendingApproval()

        XCTAssertEqual(supervisor.raiseAttentionBanners(), [])
        XCTAssertEqual(posted, [])
    }

    func testABlockedTaskBannerRoutesToTheTaskItNames() throws {
        let task = try fixture.tasks.create(
            projectId: fixture.project.id, title: "Add the sidebar", body: nil, acceptance: nil,
            priority: nil, column: .running, origin: .human, epicId: nil
        )
        try fixture.tasks.setBlocked(task.id, true, reason: "need creds")

        XCTAssertEqual(supervisor.raiseAttentionBanners().map(\.reason), [.blockedWorker])
        let route = try XCTUnwrap(posted.first?.route)
        XCTAssertEqual(route.projectId, fixture.project.id)
        guard case .blockedTask = route.subject else {
            return XCTFail("expected a blocked-task subject, got \(route.subject)")
        }
    }

    // MARK: - Nothing bypasses the seam

    /// The gate lives in `post`, so a banner posted straight through `MacNotifier` would be
    /// unmutable and a click on it would land nowhere. `MacNotifier.post` is inert under `xctest`,
    /// so this is asserted against the source rather than observed — the technique
    /// `MessagePTYIsolationTests` uses for the same reason.
    func testTheOnlyCallerOfMacNotifierPostIsTheSupervisorSeam() throws {
        let sources = Self.repoRoot.appendingPathComponent("Sources")
        let urls = FileManager.default
            .enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []

        var callers: [String] = []
        for url in urls {
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(separator: "\n") where line.contains("MacNotifier.shared.post(") {
                callers.append("\(url.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }

        XCTAssertEqual(
            callers,
            ["WorkerSupervisor.swift: MacNotifier.shared.post(title: $0, body: $1, route: $2)"],
            "every banner has to leave through WorkerSupervisor.postBanner so it is gated and routed"
        )
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
