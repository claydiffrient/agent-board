import AgentBoardCore
import AgentBoardRuntime
import Foundation
import XCTest
@testable import AgentBoard

/// SwiftTerm's `processTerminated(source:exitCode:)` is exercised directly through
/// `terminal.processDelegate`, the same entry point the real child process callback uses, so these
/// assert the decode without spawning a session.
@MainActor
final class OrchestratorConsoleTests: XCTestCase {
    private var fixture: SupervisorFixture!

    override func setUp() async throws {
        fixture = try SupervisorFixture.make()
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    /// `processTerminated` hands off to `processExited` through a `Task`, not synchronously, so the
    /// assertion has to wait for it the way `ShellConsoleTests` waits for a real process exit.
    private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await _Concurrency.Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    func testANonZeroExitRecordsTheDecodedCodeNotTheRawWaitStatus() async throws {
        let console = try fixture.supervisor.orchestratorConsole(projectId: fixture.project.id)

        console.terminal.processDelegate?.processTerminated(source: console.terminal, exitCode: 7 << 8)

        let exited = await waitUntil { if case .exited = console.state { return true }; return false }
        XCTAssertTrue(exited, "the console never recorded the exit: \(console.state)")
        XCTAssertEqual(console.state, .exited(7), "the raw waitpid status leaked into the state")
    }

    func testASignalDeathIsNotReportedAsAnExitCode() async throws {
        let console = try fixture.supervisor.orchestratorConsole(projectId: fixture.project.id)

        console.terminal.processDelegate?.processTerminated(source: console.terminal, exitCode: SIGTERM)

        let exited = await waitUntil { if case .exited = console.state { return true }; return false }
        XCTAssertTrue(exited, "the console never recorded the exit: \(console.state)")
        XCTAssertEqual(console.state, .exited(128 + SIGTERM), "a signal death was reported as an exit code")
    }

    /// Rita's case against bf2970b0: a nudge while the compaction command is still going out in
    /// bursts. A raw-mode `cat` records the exact bytes the PTY delivered, in order.
    func testAnInjectionStartedMidCompactionWaitsForTheCompactionLineAndItsReturn() async throws {
        let console = try fixture.supervisor.orchestratorConsole(projectId: fixture.project.id)
        let received = FileManager.default.temporaryDirectory
            .appendingPathComponent("orchestrator-pty-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: received) }
        console.terminal.startProcess(
            executable: "/bin/sh",
            args: ["-c", "stty raw -echo; exec cat > '\(received.path)'"]
        )
        defer { console.terminal.terminate() }
        let ready = await waitUntil { FileManager.default.fileExists(atPath: received.path) }
        XCTAssertTrue(ready, "the recording child never started")

        console.turnEnded()
        console.contextPressureObserved(ContextPressure(usedTokens: 900_000, limitTokens: 1_000_000))
        try ReportStore(fixture.db).insert(
            projectId: fixture.project.id, taskId: nil, sessionId: nil, kind: .comment, body: "Done."
        )
        console.nudge()

        let expected = OrchestratorCompaction.command + "\r" + "[agent-board] 1 reports pending. Call list_reports.\r"
        let length = expected.utf8.count
        _ = await waitUntil { ((try? Data(contentsOf: received))?.count ?? 0) >= length }
        XCTAssertEqual(String(decoding: try Data(contentsOf: received), as: UTF8.self), expected)
    }
}
