import AgentBoardCore
import AgentBoardRuntime
import Foundation
import XCTest
@testable import AgentBoard

/// The stall and cap banners each name a specific session, so a click on either should land on
/// that session's Status row rather than the Orchestrator screen. `meter` is `WorkerSupervisor`'s
/// per-session evaluation that both `noteStall` and `enforce` live behind; it is exposed
/// internally (not private) so these tests can drive one session through it directly instead of
/// waiting on the real metering timer.
@MainActor
final class StallAndCapRouteTests: XCTestCase {
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
        fixture.cleanUp()
        fixture = nil
    }

    private func runningTask() throws -> BoardTask {
        try fixture.tasks.create(
            projectId: fixture.project.id, title: "Chase the flake", body: nil, acceptance: nil,
            priority: nil, column: .running, origin: .human, epicId: nil
        )
    }

    private func millis(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

    func testAStalledWorkerBannerRoutesToTheSessionItNames() async throws {
        let task = try runningTask()
        let session = AgentSession(
            sessionId: "session-stall", projectId: fixture.project.id, taskId: task.id, role: .worker,
            cwd: fixture.repo.path, state: .running,
            lastActivity: millis(Date().addingTimeInterval(-120))
        )
        try fixture.sessions.insert(session)

        await supervisor.meter(
            session,
            limits: CapLimits(maxTokens: nil, maxWallClockSeconds: 100_000, maxIdleSeconds: 100_000),
            stallSeconds: 60
        )

        XCTAssertEqual(posted.map(\.title), ["Worker may be stuck — Demo"])
        XCTAssertEqual(
            posted.first?.route,
            NotificationRoute(projectId: fixture.project.id, subject: .session(session.sessionId))
        )
    }

    func testACapBreachBannerRoutesToTheSessionItNames() async throws {
        let task = try runningTask()
        let session = AgentSession(
            sessionId: "session-cap", projectId: fixture.project.id, taskId: task.id, role: .worker,
            cwd: fixture.repo.path, state: .running, tokensIn: 5_000, tokensOut: 5_000
        )
        try fixture.sessions.insert(session)

        await supervisor.meter(
            session,
            limits: CapLimits(maxTokens: 1_000, maxWallClockSeconds: 100_000, maxIdleSeconds: 100_000),
            stallSeconds: 100_000
        )

        XCTAssertEqual(posted.map(\.title), ["Worker stopped at cap — Demo"])
        XCTAssertEqual(
            posted.first?.route,
            NotificationRoute(projectId: fixture.project.id, subject: .session(session.sessionId))
        )

        // `enforce` is what killed it: the row the route points at is really stopped.
        let stopped = try XCTUnwrap(fixture.sessions.get(session.sessionId))
        XCTAssertEqual(stopped.state, .failed)
    }

    /// A cap kill leaves a `.failed` row, which is one of the terminal states the Status roster
    /// keeps visible for an hour after it ends (`SessionVisibilityTests` pins the window itself).
    /// This ties the two together: the subject the cap banner now carries opens a screen where
    /// that just-stopped session is actually on the roster, not an empty one.
    func testRoutingToAStoppedSessionLandsOnAStatusRosterThatShowsIt() {
        let now = Date()
        let stopped = AgentSession(
            sessionId: "session-stopped", projectId: "p-1", role: .worker, cwd: "/tmp", state: .failed,
            startedAt: millis(now.addingTimeInterval(-300)), endedAt: millis(now)
        )

        let route = NotificationRoute(projectId: "p-1", subject: .session(stopped.sessionId))
        XCTAssertEqual(route.screen, .status)

        let roster = SessionVisibility.roster([stopped], now: now)
        XCTAssertEqual(roster.visible.map(\.sessionId), [stopped.sessionId])
    }
}
