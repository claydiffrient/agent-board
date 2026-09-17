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
}
