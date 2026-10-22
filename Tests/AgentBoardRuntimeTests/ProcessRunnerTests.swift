import XCTest
@testable import AgentBoardRuntime

final class ProcessRunnerTests: XCTestCase {
    /// One call per core is enough to starve a stderr reader that waits on a dispatch queue: every
    /// call then sat out `pipeDrainTimeout` and threw, as a metering tick on a 3-core CI runner did.
    func testAsManyConcurrentRunsAsCoresAllReturnBothStreams() async throws {
        let results = try await withThrowingTaskGroup(of: CommandResult.self) { group in
            for _ in 0..<ProcessInfo.processInfo.activeProcessorCount {
                group.addTask {
                    try ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo out; echo err >&2"])
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        for result in results {
            XCTAssertEqual(result.stdout, "out\n")
            XCTAssertEqual(result.stderr, "err\n")
        }
    }
}
