import AgentBoardCore
import Foundation
import XCTest
@testable import AgentBoard

private final class LowDisk: DiskSpaceMeasuring, @unchecked Sendable {
    var paths: [URL] = []

    func volumes(holding paths: [URL]) -> [VolumeSpace] {
        self.paths = paths
        return [VolumeSpace(mountPoint: "/Volumes/Work", name: "Work", availableBytes: 12_300_000_000)]
    }
}

@MainActor
final class DiskSpaceNotificationTests: XCTestCase {
    func testALowVolumeOnTheTickPostsOneBannerAndReachesASubscriber() async throws {
        let fixture = try SupervisorFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.supportDir) }
        let disk = LowDisk()
        fixture.supervisor.diskSpace = DiskSpaceMonitor(measurer: disk, settings: { .defaults })
        var banners: [String] = []
        fixture.supervisor.postBanner = { title, body, _ in banners.append("\(title): \(body)") }
        var events = fixture.supervisor.lowDiskSpaceEvents().makeAsyncIterator()

        await fixture.supervisor.meterTick()
        await fixture.supervisor.meterTick()

        XCTAssertEqual(banners, ["Low disk space: Work has 12.3 GB free, below 25 GB."])
        XCTAssertEqual(
            Set(disk.paths.map(\.path)),
            [fixture.project.repoPath, fixture.project.worktreeRoot]
        )
        let event = await events.next()
        XCTAssertEqual(event?.volume.name, "Work")
    }
}
