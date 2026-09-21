import AgentBoardCore
import AppKit
import Foundation
import XCTest
@testable import AgentBoard

/// Records what was asked of IOKit without asking IOKit anything. SPEC §8.3.
final class RecordingSleepAssertion: SleepAssertion {
    private(set) var holds: [String] = []
    private(set) var releases = 0
    private(set) var isHeld = false

    func hold(named name: String) {
        guard !isHeld else { return }
        holds.append(name)
        isHeld = true
    }

    func release() {
        guard isHeld else { return }
        releases += 1
        isHeld = false
    }
}

@MainActor
final class SleepGuardTests: XCTestCase {
    private func makeGuard() -> (SleepGuard, RecordingSleepAssertion, UserDefaults) {
        let assertion = RecordingSleepAssertion()
        let suite = "SleepGuardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (SleepGuard(assertion: assertion, defaults: defaults), assertion, defaults)
    }

    func testTheSettingDefaultsOn() {
        let (sleepGuard, assertion, _) = makeGuard()
        XCTAssertTrue(sleepGuard.isEnabled)

        sleepGuard.apply([.running])

        XCTAssertTrue(sleepGuard.isHolding)
        XCTAssertEqual(assertion.holds, [SleepPrevention.assertionName])
    }

    func testTurningTheSettingOffReleasesImmediately() {
        let (sleepGuard, assertion, defaults) = makeGuard()
        sleepGuard.apply([.running, .running])
        XCTAssertTrue(assertion.isHeld)

        sleepGuard.isEnabled = false

        XCTAssertFalse(assertion.isHeld, "turning the setting off left the assertion held")
        XCTAssertEqual(assertion.releases, 1)
        XCTAssertFalse(sleepGuard.isHolding)
        XCTAssertEqual(defaults.object(forKey: SleepGuard.defaultsKey) as? Bool, false)
    }

    func testTurningItBackOnRetakesTheAssertionWithoutANewApply() {
        let (sleepGuard, assertion, _) = makeGuard()
        sleepGuard.apply([.running])
        sleepGuard.isEnabled = false

        sleepGuard.isEnabled = true

        XCTAssertTrue(assertion.isHeld)
        XCTAssertEqual(assertion.holds.count, 2)
    }

    func testOffIsRememberedAcrossALaunch() {
        let (sleepGuard, _, defaults) = makeGuard()
        sleepGuard.isEnabled = false

        let relaunched = SleepGuard(assertion: RecordingSleepAssertion(), defaults: defaults)

        XCTAssertFalse(relaunched.isEnabled)
    }

    func testTheLastRunningSessionEndingReleasesTheAssertion() {
        let (sleepGuard, assertion, _) = makeGuard()
        sleepGuard.apply([.running, .idle, .completed])
        XCTAssertTrue(assertion.isHeld)

        sleepGuard.apply([.completed, .idle])
        XCTAssertTrue(assertion.isHeld, "an idle session is still live")

        sleepGuard.apply([.completed, .completed])

        XCTAssertFalse(assertion.isHeld, "the last live session ended and the assertion was still held")
        XCTAssertEqual(assertion.releases, 1)
        XCTAssertEqual(sleepGuard.activeCount, 0)
    }

    func testTheAssertionIsTakenOnceNotOncePerTick() {
        let (sleepGuard, assertion, _) = makeGuard()
        for _ in 0..<5 { sleepGuard.apply([.running]) }
        XCTAssertEqual(assertion.holds.count, 1)
    }

    func testQuittingWithWorkersStillRunningReleasesTheAssertion() {
        let (sleepGuard, assertion, _) = makeGuard()
        let center = NotificationCenter()
        sleepGuard.releaseOnTermination(center: center)
        sleepGuard.apply([.running, .running, .blocked])
        XCTAssertTrue(assertion.isHeld)

        center.post(name: NSApplication.willTerminateNotification, object: nil)

        XCTAssertFalse(assertion.isHeld, "the app quit holding a power assertion")
        XCTAssertEqual(assertion.releases, 1)
        XCTAssertFalse(sleepGuard.isHolding)
    }

    func testTheFooterTellsTheUserTheLidIsNotCovered() {
        let (sleepGuard, _, _) = makeGuard()
        sleepGuard.apply([.running])

        XCTAssertEqual(sleepGuard.footerLabel, "Keeping this Mac awake — idle sleep only")
        XCTAssertTrue(sleepGuard.footerHelp.contains("Closing the lid"))
    }
}

/// The assertion follows the `agent_session` rows the board can see, not a spawn-side counter.
@MainActor
final class SleepGuardSupervisorTests: XCTestCase {
    private var fixture: SupervisorFixture!
    private var assertion: RecordingSleepAssertion!
    private var sleepGuard: SleepGuard!

    override func setUp() async throws {
        assertion = RecordingSleepAssertion()
        sleepGuard = SleepGuard(
            assertion: assertion,
            defaults: UserDefaults(suiteName: "SleepGuardSupervisorTests.\(UUID().uuidString)")!
        )
        fixture = try SupervisorFixture.make(sleepGuard: sleepGuard)
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    func testAWorkerAtWorkHoldsTheAssertionAndStoppingItReleases() async throws {
        let worker = try fixture.workerAtWork()

        await fixture.supervisor.meterTick()
        XCTAssertTrue(assertion.isHeld, "a running worker did not hold the Mac awake")
        XCTAssertEqual(assertion.holds, [SleepPrevention.assertionName])

        try await fixture.supervisor.stop(sessionId: worker.sessionId)

        XCTAssertFalse(assertion.isHeld, "the last worker stopped and the assertion was still held")
        XCTAssertEqual(assertion.releases, 1)
    }

    /// The stranded case: the process is gone but nothing reported it, so the row stays `running`
    /// and the assertion stays held. The sweep that flips the row is what releases it.
    func testAStrandedSessionKeepsHoldingUntilItsRowGoesInactive() async throws {
        let worker = try fixture.workerAtWork()
        await fixture.supervisor.meterTick()
        XCTAssertTrue(assertion.isHeld)

        await fixture.supervisor.meterTick()
        XCTAssertTrue(assertion.isHeld, "a stranded row is still active; the assertion must stay")

        try fixture.sessions.setState(worker.sessionId, .failed)
        await fixture.supervisor.meterTick()

        XCTAssertFalse(assertion.isHeld, "the swept session left the assertion held")
    }

    func testNothingRunningHoldsNothing() async throws {
        await fixture.supervisor.meterTick()
        XCTAssertFalse(assertion.isHeld)
        XCTAssertTrue(assertion.holds.isEmpty)
    }
}
