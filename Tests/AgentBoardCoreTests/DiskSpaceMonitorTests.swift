import AgentBoardCore
import Foundation
import XCTest

private final class FakeDisk: DiskSpaceMeasuring, @unchecked Sendable {
    var freeGB: Double = 100
    var measurements = 0

    func volumes(holding paths: [URL]) -> [VolumeSpace] {
        measurements += 1
        return [VolumeSpace(mountPoint: "/", name: "Macintosh HD", availableBytes: Int64(freeGB * 1e9))]
    }
}

@MainActor
final class DiskSpaceMonitorTests: XCTestCase {
    private let disk = FakeDisk()
    private let clock = FakeSystemClock()
    private var settings = DiskSpaceSettings.defaults

    private func makeMonitor() -> DiskSpaceMonitor {
        DiskSpaceMonitor(measurer: disk, clock: clock, settings: { [unowned self] in settings })
    }

    private func check(_ monitor: DiskSpaceMonitor, freeGB: Double) -> [LowDiskSpaceEvent] {
        disk.freeGB = freeGB
        clock.advanceAwake(seconds: 5 * 60)
        return monitor.tick(paths: [URL(fileURLWithPath: "/tmp")])
    }

    func testOneEventPerDropWithNoRepeatUntilSpaceRisesAboveTheRearmThreshold() {
        let monitor = makeMonitor()

        XCTAssertEqual(check(monitor, freeGB: 40), [])
        let first = check(monitor, freeGB: 20)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?.body, "Macintosh HD has 20.0 GB free, below 25 GB.")

        XCTAssertEqual(check(monitor, freeGB: 18), [], "still below the low threshold")
        XCTAssertEqual(check(monitor, freeGB: 30), [], "between the thresholds")
        XCTAssertEqual(check(monitor, freeGB: 24), [], "dropped again without having rearmed")

        XCTAssertEqual(check(monitor, freeGB: 36), [])
        XCTAssertEqual(check(monitor, freeGB: 22).count, 1, "rearmed above 35 GB, so the next drop fires")
    }

    func testTurnedOffItNeitherMeasuresNorFires() {
        settings.enabled = false
        let monitor = makeMonitor()

        XCTAssertEqual(check(monitor, freeGB: 40), [])
        XCTAssertEqual(check(monitor, freeGB: 5), [])
        XCTAssertEqual(disk.measurements, 0)
    }

    func testSleepDoesNotCountTowardTheCheckInterval() {
        let monitor = makeMonitor()
        _ = monitor.tick(paths: [])
        XCTAssertEqual(disk.measurements, 1)

        clock.suspend(seconds: 3 * 60 * 60)
        _ = monitor.tick(paths: [])
        XCTAssertEqual(disk.measurements, 1, "three hours asleep is no awake time at all")

        clock.advanceAwake(seconds: 5 * 60)
        _ = monitor.tick(paths: [])
        XCTAssertEqual(disk.measurements, 2)
    }

    func testTwoPathsOnOneVolumeAreMeasuredOnceIncludingOneThatDoesNotExistYet() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let volumes = SystemDiskSpace().volumes(holding: [dir, dir.appendingPathComponent("not/yet/created")])

        XCTAssertEqual(volumes.count, 1)
        XCTAssertGreaterThan(volumes.first?.availableBytes ?? 0, 0)
    }
}
