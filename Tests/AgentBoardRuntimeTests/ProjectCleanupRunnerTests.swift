import AgentBoardCore
import Darwin
import XCTest
@testable import AgentBoardRuntime

final class ProjectCleanupRunnerTests: XCTestCase {
    private var checkout: URL!

    override func setUpWithError() throws {
        checkout = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: checkout)
    }

    func testASuccessfulCommandRunsInTheCheckoutAndRecordsItsExitStatusAndOutputTail() throws {
        let resolved = try XCTUnwrap(realpath(checkout.path, nil).map { String(cString: $0) })

        let result = try XCTUnwrap(ProjectCleanupRunner.run(
            ProjectCleanupCommand(command: "pwd -P; echo pruned >&2"), in: checkout, environment: [:]
        ))

        XCTAssertEqual(result.outcome, .exited(0))
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.outputTail, "\(resolved)\npruned")
    }

    func testACommandThatOutlivesItsDeadlineIsKilledWithItsWholeProcessGroup() throws {
        let pidFile = checkout.appendingPathComponent("background.pid")

        let result = try XCTUnwrap(ProjectCleanupRunner.run(
            ProjectCleanupCommand(
                command: "sleep 60 & echo $! > '\(pidFile.path)'; echo started; sleep 60", timeoutSeconds: 1
            ),
            in: checkout, environment: [:]
        ))

        XCTAssertEqual(result.outcome, .timedOut)
        XCTAssertEqual(result.outputTail, "started")
        XCTAssertTrue(result.summary.contains("did not finish within 1s"), result.summary)
        let background = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        var gone = false
        for _ in 0..<50 where !gone {
            gone = kill(background, 0) != 0 && errno == ESRCH
            if !gone { usleep(100_000) }
        }
        XCTAssertTrue(gone, "the command's background child outlived the deadline")
    }

    func testABlankCommandRunsNothing() {
        var settings = ProjectSettings()
        settings.cleanupCommand = "  \n"

        XCTAssertNil(settings.projectCleanup)
        XCTAssertNil(ProjectCleanupRunner.run(settings.projectCleanup, in: checkout, environment: [:]))
    }
}
