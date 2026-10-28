import Darwin
import XCTest
@testable import AgentBoardRuntime

final class DescriptorLogTests: XCTestCase {
    func testACheckedCloseOfAnAlreadyClosedDescriptorReportsItsSite() throws {
        var ends: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&ends), 0)
        defer { close(ends[1]) }
        // The highest number the table allows: no other thread is handed it once it is freed.
        let fd = fcntl(ends[0], F_DUPFD, getdtablesize() - 1)
        XCTAssertGreaterThanOrEqual(fd, 0)
        close(ends[0])
        var reports: [String] = []

        DescriptorLog.closeChecked(fd, site: "first close") { reports.append($0) }
        DescriptorLog.closeChecked(fd, site: "second close") { reports.append($0) }

        XCTAssertEqual(reports.count, 1)
        let report = try XCTUnwrap(reports.first)
        XCTAssertTrue(report.contains("second close"), report)
        XCTAssertTrue(report.contains("close(\(fd))"), report)
        XCTAssertTrue(report.contains("errno \(EBADF)"), report)
    }
}
