import AgentBoardBridge
import AgentBoardCore
import AgentBoardRuntime
import AgentBoardServer
import Foundation
import XCTest
@testable import AgentBoard

/// Wall clock and uptime move together here: nothing in these tests is asleep, only silent.
private final class AwakeOnlyClock: SystemClock, @unchecked Sendable {
    var wallMillis: Int64
    var uptimeSeconds: TimeInterval = 10_000

    init(wallMillis: Int64) {
        self.wallMillis = wallMillis
    }

    func advance(seconds: TimeInterval) {
        wallMillis += Int64(seconds * 1000)
        uptimeSeconds += seconds
    }
}

/// A worker was reaped by the idle cap with 376 counted tokens and `Bash` as its last tool: it
/// spawned, issued one command, and was executed mid-command for "no activity for 15 minutes".
/// `PostToolUse` fires only when a tool returns, and a cold `swift build` here measures 544s, so
/// the activity clock read a working session as silent for the whole of it.
///
/// Every case below drives the real hook sink over the supervisor's own database, so what is being
/// tested is the hook path, not a field a test set.
@MainActor
final class InFlightToolCallCapTests: XCTestCase {
    /// The project defaults these tests lean on.
    private let idleCap: TimeInterval = 300
    private let stallThreshold: TimeInterval = 120

    private var fixture: SupervisorFixture!
    private var clock: AwakeOnlyClock!
    private var hooks: StoreHookSink!
    private var banners: [String] = []

    override func setUp() async throws {
        clock = AwakeOnlyClock(wallMillis: .nowMillis)
        fixture = try SupervisorFixture.make(sleepLedger: SleepLedger(clock: clock))
        hooks = StoreHookSink(db: fixture.db, events: LateBoundSink())
        banners = []
        fixture.supervisor.isFrontmost = { true }
        fixture.supervisor.postBanner = { [weak self] title, _, _ in self?.banners.append(title) }
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    private func worker() throws -> (sessionId: String, identity: TokenIdentity) {
        let at = try fixture.workerAtWork()
        return (
            at.sessionId,
            TokenIdentity(
                token: at.token, scope: .worker, projectId: fixture.project.id,
                sessionId: at.sessionId, taskId: at.task.id
            )
        )
    }

    /// Re-pins the test clock to the instant the hook actually wrote, so the boundary cases below
    /// are exact rather than a few milliseconds short of the bound they are asserting.
    private func startBuild(_ session: (sessionId: String, identity: TokenIdentity)) async throws {
        _ = await hooks.handle(
            HookEvent(
                name: "PreToolUse", sessionId: session.sessionId, toolName: "Bash",
                toolCommand: "swift build", rawJSON: "{}"
            ),
            identity: session.identity
        )
        clock.wallMillis = try XCTUnwrap(fixture.sessions.get(session.sessionId)?.toolStartedAt)
    }

    private func finishBuild(_ session: (sessionId: String, identity: TokenIdentity)) async throws {
        _ = await hooks.handle(
            HookEvent(name: "PostToolUse", sessionId: session.sessionId, toolName: "Bash", rawJSON: "{}"),
            identity: session.identity
        )
        clock.wallMillis = try XCTUnwrap(fixture.sessions.get(session.sessionId)?.lastActivity)
    }

    private func state(_ sessionId: String) throws -> SessionState {
        try XCTUnwrap(fixture.sessions.get(sessionId)).state
    }

    private func raiseCap(wallClockSeconds: Int) throws {
        var settings = fixture.project.settings
        settings.caps.maxWallClockSeconds = wallClockSeconds
        try ProjectStore(fixture.db).updateSettings(fixture.project.id, settings)
    }

    func testAWorkerInsideARunningCommandIsNotReapedByTheIdleCap() async throws {
        let session = try worker()
        try await startBuild(session)

        clock.advance(seconds: idleCap + 244)
        await fixture.supervisor.meterTick()

        XCTAssertEqual(try state(session.sessionId), .running)
        let stopped = await fixture.runtime.stopped
        XCTAssertTrue(stopped.isEmpty, "a worker mid-command was stopped: \(stopped)")
    }

    func testAWorkerWhoseCommandReturnedAndThenWentSilentStillBreachesTheCap() async throws {
        let session = try worker()
        try await startBuild(session)
        try await finishBuild(session)

        clock.advance(seconds: idleCap + 244)
        await fixture.supervisor.meterTick()

        XCTAssertEqual(try state(session.sessionId), .failed)
        let reason = try XCTUnwrap(fixture.sessions.get(session.sessionId)?.stopReason)
        XCTAssertTrue(reason.contains("idle cap"), reason)
    }

    /// The bound: an in-flight call excuses 6 × the idle cap and not a second more, so a worker
    /// genuinely wedged inside a hung command is still reaped. The elapsed cap is raised out of the
    /// way first — at its 1800s default it would reach this worker at the same moment.
    func testACommandThatNeverReturnsIsReapedAtSixTimesTheIdleCap() async throws {
        try raiseCap(wallClockSeconds: 86_400)
        let session = try worker()
        try await startBuild(session)

        clock.advance(seconds: idleCap * 6 - 1)
        await fixture.supervisor.meterTick()
        XCTAssertEqual(try state(session.sessionId), .running, "reaped one second early")

        clock.advance(seconds: 1)
        await fixture.supervisor.meterTick()
        XCTAssertEqual(try state(session.sessionId), .failed)
    }

    func testTheStallBannerIsNotRaisedWhileACommandIsRunning() async throws {
        let session = try worker()
        try await startBuild(session)

        clock.advance(seconds: stallThreshold + 424)
        await fixture.supervisor.meterTick()

        XCTAssertEqual(banners, [], "a worker mid-command was reported as stuck")
    }

    /// The stall indicator's own bound is 6 × `stallSeconds` — 720s against the 1800s the cap
    /// allows the same call, so a wedged command still surfaces to the human before anything kills
    /// the worker over it.
    func testAWedgedCommandStillSurfacesAsStalled() async throws {
        let session = try worker()
        try await startBuild(session)

        clock.advance(seconds: stallThreshold * 6)
        await fixture.supervisor.meterTick()

        XCTAssertEqual(banners, ["Worker may be stuck — Demo"])
        XCTAssertEqual(try state(session.sessionId), .running, "surfacing a stall must not kill it")
    }
}
