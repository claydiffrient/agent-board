import AgentBoardCore
import XCTest
@testable import AgentBoardRuntime

/// SPEC §5.1: completion checks run one at a time across the app and keep a failure's output tail.
final class CompletionCheckQueueTests: XCTestCase {
    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("completion-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    func testTwoCompletionsDoNotRunTheirChecksAtTheSameTime() async {
        let held = sandbox.appendingPathComponent("held").path
        let command = "/bin/mkdir '\(held)' && /bin/sleep 1 && /bin/rmdir '\(held)'"
        let queue = CompletionCheckQueue()

        async let first = queue.run([command], timeoutSeconds: 60, in: sandbox)
        async let second = queue.run([command], timeoutSeconds: 60, in: sandbox)
        let checks = await [first, second]

        XCTAssertEqual(checks.map(\.passed), [true, true], checks.map(\.report).joined(separator: "\n"))
    }

    func testAFailingCommandKeepsItsTailAndStopsTheRest() {
        let check = RefreshVerifier.completionCheck(
            ["echo building; echo 'boom at line 12'; exit 3", "echo never"], timeoutSeconds: 60, in: sandbox
        )

        XCTAssertEqual(check.steps.map(\.result), [.failed, .notRun])
        XCTAssertEqual(check.steps.first?.exitStatus, 3)
        XCTAssertEqual(check.failure?.outputTail.contains("boom at line 12"), true)
        XCTAssertNotNil(check.finishedAt)
    }
}
