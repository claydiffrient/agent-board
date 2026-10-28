import AgentBoardBridge
import AgentBoardCore
import AgentBoardRuntime
import Foundation
import XCTest
@testable import AgentBoard

/// Wall clock and uptime move independently, so a test can stage a lid-close.
private final class FakeSystemClock: SystemClock, @unchecked Sendable {
    var wallMillis: Int64
    var uptimeSeconds: TimeInterval

    init(wallMillis: Int64, uptimeSeconds: TimeInterval = 10_000) {
        self.wallMillis = wallMillis
        self.uptimeSeconds = uptimeSeconds
    }

    func advanceAwake(seconds: TimeInterval) {
        wallMillis += Int64(seconds * 1000)
        uptimeSeconds += seconds
    }

    /// Wall time passes, `CLOCK_UPTIME_RAW` does not.
    func suspend(seconds: TimeInterval) {
        wallMillis += Int64(seconds * 1000)
    }
}

/// Closing the lid used to execute every running worker: the metering tick measured idle time on
/// the wall clock, and a suspended `claude --bg` process produces no activity while the machine is
/// asleep. Three healthy sessions died this way on 2026-09-14/15, one of them holding finished,
/// committed, green work.
@MainActor
final class IdleCapSleepTests: XCTestCase {
    /// Past the 300s default idle cap by four times over.
    private let silence: TimeInterval = 1_200

    private var fixture: SupervisorFixture!
    private var clock: FakeSystemClock!

    override func tearDown() async throws {
        await fixture?.cleanUp()
        fixture = nil
        clock = nil
    }

    /// A supervisor whose ledger took its first sample `silence` seconds ago — the app was running
    /// when the lid closed — over one running worker that has been silent ever since.
    private func silentWorker() throws -> String {
        clock = FakeSystemClock(wallMillis: .nowMillis - Int64(silence * 1000))
        let ledger = SleepLedger(clock: clock)
        fixture = try SupervisorFixture.make(sleepLedger: ledger)
        let sessionId = try backdatedWorker()
        _ = ledger.reading()
        return sessionId
    }

    private func backdatedWorker() throws -> String {
        let worker = try fixture.workerAtWork()
        try fixture.db.writer.write { [at = clock.wallMillis] db in
            try db.execute(
                sql: "UPDATE agent_session SET started_at = ?, last_activity = ? WHERE session_id = ?",
                arguments: [at, at, worker.sessionId]
            )
        }
        return worker.sessionId
    }

    private func session(_ sessionId: String) throws -> AgentSession {
        try XCTUnwrap(fixture.sessions.get(sessionId))
    }

    func testAWorkerIsNotReapedForTheMinutesTheLaptopSpentAsleep() async throws {
        let sessionId = try silentWorker()

        clock.suspend(seconds: silence - 5)
        clock.advanceAwake(seconds: 5)
        await fixture.supervisor.meterTick()

        XCTAssertEqual(try session(sessionId).state, .running)
        let stopped = await fixture.runtime.stopped
        XCTAssertTrue(stopped.isEmpty, "nothing should have been stopped, got \(stopped)")
    }

    func testAWorkerSilentWhileTheMachineStayedAwakeStillHitsTheIdleCap() async throws {
        let sessionId = try silentWorker()

        clock.advanceAwake(seconds: silence)
        await fixture.supervisor.meterTick()

        XCTAssertEqual(try session(sessionId).state, .failed)
        let reason = try XCTUnwrap(session(sessionId).stopReason)
        XCTAssertTrue(reason.contains("idle cap"), reason)
    }

    /// The elapsed cap rides the same clock, so a worker whose whole run was one long suspend is
    /// not executed for it either.
    func testTheElapsedCapAlsoSurvivesASuspend() async throws {
        let sessionId = try silentWorker()
        var settings = try XCTUnwrap(ProjectStore(fixture.db).get(fixture.project.id)?.settings)
        settings.caps.maxWallClockSeconds = 600
        settings.caps.maxIdleSeconds = 86_400
        try ProjectStore(fixture.db).updateSettings(fixture.project.id, settings)

        clock.suspend(seconds: silence - 5)
        clock.advanceAwake(seconds: 5)
        await fixture.supervisor.meterTick()

        XCTAssertEqual(try session(sessionId).state, .running)
    }

    /// SPEC §8: dark wakes accrue awake time with the lid shut, so a worker waiting on the wake
    /// resume would otherwise be idled out before the lid opens.
    func testAWorkerWaitingForWakeAfterASleepCutIsSparedTheIdleCapUntilItsResume() async throws {
        let waiting = try silentWorker()
        let other = try backdatedWorker()
        await fixture.supervisor.start()
        try XCTSkipIf(fixture.supervisor.serverPort == nil, "the board server could not bind a port")
        let payload = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "StopFailure", "session_id": waiting,
            "error": "server_error", "last_assistant_message": SleepCutTurn.message,
        ])
        try HookEventStore(fixture.db).append(
            sessionId: waiting, event: "StopFailure", payload: String(decoding: payload, as: UTF8.self)
        )
        await fixture.runtime.failNextResume(FixtureError("claude --bg --resume failed"))
        await fixture.supervisor.workerTurnCutBySleep(projectId: fixture.project.id, sessionId: waiting)

        clock.advanceAwake(seconds: silence)
        await fixture.supervisor.meterTick()

        XCTAssertEqual(try session(waiting).state, .running)
        XCTAssertEqual(try session(other).state, .failed)

        await fixture.supervisor.screensDidWake()
        let resumed = await fixture.runtime.resumed
        XCTAssertEqual(resumed, [waiting])
        await fixture.supervisor.meterTick()

        XCTAssertEqual(try session(waiting).state, .running)
    }
}
