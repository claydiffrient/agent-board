import XCTest
@testable import AgentBoardRuntime

final class ProcessRunnerTests: XCTestCase {
    private static let shell = URL(fileURLWithPath: "/bin/sh")

    /// One call per core is enough to starve a stderr reader that waits on a dispatch queue: every
    /// call then sat out `pipeDrainTimeout` and threw, as a metering tick on a 3-core CI runner did.
    func testAsManyConcurrentRunsAsCoresAllReturnBothStreams() async throws {
        // Resolved before any burst, as AppComposition does at launch; its lookup starves the same way.
        _ = LoginShellPath.resolved
        try await assertBurstReturnsBothStreams {
            try ProcessRunner.run(executable: Self.shell, arguments: ["-c", "echo out; echo err >&2"])
        }
    }

    /// The timed variant starved the same way, but past its grace it returned empty output instead
    /// of throwing, so `claude agents --json --all` read as no agents.
    func testAsManyConcurrentTimedRunsAsCoresAllReturnBothStreams() async throws {
        _ = LoginShellPath.resolved
        try await assertBurstReturnsBothStreams {
            try ProcessRunner.run(executable: Self.shell, arguments: ["-c", "echo out; echo err >&2"], timeout: 30)
        }
    }

    func testATimedRunReturnsAtTheChildsExitWhileAGrandchildHoldsItsPipes() throws {
        let result = try ProcessRunner.run(executable: Self.shell, arguments: ["-c", "sleep 60 & echo $!"], timeout: 10)
        let grandchild = try XCTUnwrap(pid_t(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
        kill(grandchild, SIGKILL)
        XCTAssertEqual(result.status, 0)
    }

    private func assertBurstReturnsBothStreams(_ run: @escaping @Sendable () throws -> CommandResult) async throws {
        let results = try await withThrowingTaskGroup(of: CommandResult.self) { group in
            for _ in 0..<ProcessInfo.processInfo.activeProcessorCount {
                group.addTask { try run() }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        for result in results {
            XCTAssertEqual(result.stdout, "out\n")
            XCTAssertEqual(result.stderr, "err\n")
        }
    }
}
