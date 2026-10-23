import AgentBoardRuntime
import Darwin
import Foundation
import XCTest

final class SessionProcessReaperTests: XCTestCase {
    /// SPEC §8.5: a pid freed after the listing was read and handed to a new process is not the host.
    func testAProcessStartedAfterTheListingIsNotItsHost() throws {
        let listedAt = Int64(Date().timeIntervalSince1970 * 1_000_000) - 1_000_000
        let newcomer = Process()
        newcomer.executableURL = URL(fileURLWithPath: "/bin/sleep")
        newcomer.arguments = ["600"]
        try newcomer.run()
        defer { newcomer.terminate() }
        let pid = newcomer.processIdentifier
        let now = Int64(Date().timeIntervalSince1970 * 1_000_000)

        XCTAssertNil(SessionProcessReaper.host(pid, listedAtMicros: listedAt, isClaude: { _ in true }))
        XCTAssertEqual(SessionProcessReaper.host(pid, listedAtMicros: now, isClaude: { _ in true })?.pid, pid)
    }
}
