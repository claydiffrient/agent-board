import AgentBoardCore
import Foundation
import XCTest

/// Wall clock and uptime move independently, so a test can stage a lid-close.
final class FakeSystemClock: SystemClock, @unchecked Sendable {
    var wallMillis: Int64
    var uptimeSeconds: TimeInterval

    init(wallMillis: Int64 = 1_700_000_000_000, uptimeSeconds: TimeInterval = 10_000) {
        self.wallMillis = wallMillis
        self.uptimeSeconds = uptimeSeconds
    }

    func advanceAwake(seconds: TimeInterval) {
        wallMillis += Int64(seconds * 1000)
        uptimeSeconds += seconds
    }

    /// The lid closes: wall time passes, `CLOCK_UPTIME_RAW` does not.
    func suspend(seconds: TimeInterval) {
        wallMillis += Int64(seconds * 1000)
    }
}

final class AwakeClockTests: XCTestCase {

    // MARK: - CLOCK_UPTIME_RAW on this machine

    /// The claim the whole fix rests on, checked against the real clocks rather than taken on
    /// faith: `CLOCK_UPTIME_RAW` never runs ahead of a clock that counts through a suspend, and it
    /// cannot exceed the wall time since boot. On a machine that has slept it is strictly behind
    /// both, and the gap is printed so a run on a never-slept machine is still legible.
    func testUptimeRawDoesNotCountSystemSleep() {
        var monotonic = timespec()
        clock_gettime(CLOCK_MONOTONIC, &monotonic)
        let monotonicSeconds = TimeInterval(monotonic.tv_sec) + TimeInterval(monotonic.tv_nsec) / 1_000_000_000

        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        XCTAssertEqual(sysctlbyname("kern.boottime", &boot, &size, nil, 0), 0)
        let wallSinceBoot = Date().timeIntervalSince1970 - TimeInterval(boot.tv_sec)

        let uptime = DarwinClock().uptimeSeconds
        XCTAssertGreaterThan(uptime, 0)
        XCTAssertLessThanOrEqual(uptime, monotonicSeconds + 1)
        XCTAssertLessThanOrEqual(uptime, wallSinceBoot + 1)
        print(
            "PROBE clocks: wall-since-boot \(Int(wallSinceBoot))s, CLOCK_MONOTONIC "
            + "\(Int(monotonicSeconds))s, CLOCK_UPTIME_RAW \(Int(uptime))s, "
            + "slept \(Int(monotonicSeconds - uptime))s"
        )
    }

    func testTheRealClockAdvancesBetweenReadings() {
        let clock = DarwinClock()
        let first = clock.uptimeSeconds
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertGreaterThan(clock.uptimeSeconds, first)
    }

    // MARK: - Detecting a suspend

    func testASuspendBetweenSamplesIsRecordedAsSleep() {
        let clock = FakeSystemClock()
        let ledger = SleepLedger(clock: clock)
        let started = clock.wallMillis
        _ = ledger.reading()

        clock.suspend(seconds: 1195)
        clock.advanceAwake(seconds: 5)
        let awake = ledger.reading()

        XCTAssertEqual(awake.sleeps.count, 1)
        XCTAssertEqual(awake.sleeps.first?.millis, 1_195_000)
        XCTAssertEqual(awake.millisAwake(since: started), 5_000)
    }

    func testTimePassingWhileAwakeRecordsNoSleep() {
        let clock = FakeSystemClock()
        let ledger = SleepLedger(clock: clock)
        let started = clock.wallMillis
        _ = ledger.reading()

        clock.advanceAwake(seconds: 1200)
        let awake = ledger.reading()

        XCTAssertTrue(awake.sleeps.isEmpty)
        XCTAssertEqual(awake.millisAwake(since: started), 1_200_000)
    }

    func testSubSecondJitterIsNotMistakenForSleep() {
        let clock = FakeSystemClock()
        let ledger = SleepLedger(clock: clock)
        let started = clock.wallMillis
        _ = ledger.reading()

        clock.advanceAwake(seconds: 5)
        clock.suspend(seconds: 1)
        let awake = ledger.reading()

        XCTAssertTrue(awake.sleeps.isEmpty, "a 1s gap is scheduler jitter, not a suspend")
        XCTAssertEqual(awake.millisAwake(since: started), 6_000)
    }

    func testEverySuspendIsRecordedAndSubtractedOnce() {
        let clock = FakeSystemClock()
        let ledger = SleepLedger(clock: clock)
        let started = clock.wallMillis
        _ = ledger.reading()

        clock.suspend(seconds: 600)
        clock.advanceAwake(seconds: 10)
        _ = ledger.reading()
        clock.suspend(seconds: 600)
        clock.advanceAwake(seconds: 10)
        let awake = ledger.reading()

        XCTAssertEqual(awake.sleeps.count, 2)
        XCTAssertEqual(awake.millisAwake(since: started), 20_000)
    }

    // MARK: - Locating a sleep against a timestamp

    func testASleepThatEndedBeforeTheTimestampIsNotSubtracted() {
        let awake = AwakeElapsed(
            nowMillis: 10_000,
            sleeps: [ObservedSleep(endedAtMillis: 4_000, millis: 3_000)]
        )
        XCTAssertEqual(awake.millisAwake(since: 5_000), 5_000)
        XCTAssertEqual(awake.millisAwake(since: 1_000), 6_000)
    }

    /// A suspend straddling the timestamp only has its later half taken off.
    func testOnlyTheOverlappingPartOfASleepIsSubtracted() {
        let awake = AwakeElapsed(
            nowMillis: 10_000,
            sleeps: [ObservedSleep(endedAtMillis: 8_000, millis: 4_000)]
        )
        XCTAssertEqual(awake.millisAwake(since: 6_000), 2_000)
    }

    func testAwakeTimeNeverGoesNegativeOrBackwards() {
        let awake = AwakeElapsed(
            nowMillis: 10_000,
            sleeps: [ObservedSleep(endedAtMillis: 10_000, millis: 60_000)]
        )
        XCTAssertEqual(awake.millisAwake(since: 9_000), 0)
        XCTAssertEqual(awake.millisAwake(since: 20_000), 0)
    }

    func testAReadingWithNoObservedSleepIsTheWallClock() {
        let now = Date()
        let awake = AwakeElapsed(now: now)
        XCTAssertEqual(awake.secondsAwake(since: now.addingTimeInterval(-90)), 90, accuracy: 0.01)
    }
}
