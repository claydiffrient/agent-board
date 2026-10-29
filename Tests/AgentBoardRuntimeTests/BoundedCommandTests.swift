import Darwin
import XCTest
@testable import AgentBoardRuntime

final class BoundedCommandTests: XCTestCase {
    func testACommandPastItsTimeoutIsStoppedWithItsWholeProcessGroup() throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("bounded-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let pidFile = sandbox.appendingPathComponent("background.pid")

        let result = try BoundedCommand.run(
            executable: "/bin/sh", arguments: ["-c", "sleep 60 & echo $! > '\(pidFile.path)'; sleep 60"],
            cwd: sandbox, environment: [:], timeout: 1
        )

        XCTAssertEqual(result.ending, .timedOut)
        let background = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        var gone = false
        for _ in 0..<50 where !gone {
            gone = kill(background, 0) != 0 && errno == ESRCH
            if !gone { usleep(100_000) }
        }
        XCTAssertTrue(gone, "the command's background child outlived the timeout")
    }
}
