import AgentBoardCore
import AgentBoardRuntime
import Foundation
import XCTest
@testable import AgentBoard

/// Git leaves the worktree on disk when its `post-checkout` setup fails, and a spawn adopts any
/// worktree it finds, so a retry must not be handed a checkout whose setup never finished.
@MainActor
final class WorktreeSetupRetryTests: XCTestCase {
    private var fixture: SupervisorFixture!

    override func setUp() async throws {
        fixture = try SupervisorFixture.make(gitRepo: true)
        await fixture.supervisor.start()
        try XCTSkipIf(fixture.supervisor.serverPort == nil, "the board server could not bind a port")
    }

    override func tearDown() async throws {
        await fixture.runtime.releaseSpawn()
        await fixture.supervisor.waitForSetup()
        await fixture.cleanUp()
        fixture = nil
    }

    func testARetryAfterAFailedSetupRunsTheSetupAgain() async throws {
        let failFlag = fixture.supportDir.appendingPathComponent("fail-setup")
        FileManager.default.createFile(atPath: failFlag.path, contents: nil)
        try installHook("""
        [ -e '\(failFlag.path)' ] && { echo "setup: bazel: command not found" >&2; exit 127; }
        touch setup-ran
        """)
        let task = try makeTask()

        _ = try await fixture.supervisor.spawnWorker(taskId: task.id)
        await fixture.supervisor.waitForSetup()
        let report = try XCTUnwrap(ReportStore(fixture.db).unconsumed(projectId: fixture.project.id).first)
        XCTAssertTrue(report.body.contains("bazel: command not found"), report.body)
        try FileManager.default.removeItem(at: failFlag)

        let spawn = try await fixture.supervisor.spawnWorker(taskId: task.id)
        await fixture.supervisor.waitForSetup()

        let worktree = URL(fileURLWithPath: try XCTUnwrap(spawn.worktreePath))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: worktree.appendingPathComponent("setup-ran").path),
            "the retry started a worker in a worktree whose setup never ran"
        )
    }

    func testSpawnAnswersWhileThePostCheckoutHookIsStillRunning() async throws {
        let gate = try installGatedHook(then: "touch setup-ran")
        let task = try makeTask()

        let spawn = try await fixture.supervisor.spawnWorker(taskId: task.id)

        let worktree = URL(fileURLWithPath: spawn.worktreePath)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: worktree.appendingPathComponent("setup-ran").path),
            "spawn waited for the post-checkout hook before answering"
        )
        XCTAssertEqual(try SessionStore(fixture.db).get(spawn.setupSessionId)?.state, .setup)
        FileManager.default.createFile(atPath: gate.path, contents: nil)
        await fixture.supervisor.waitForSetup()
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("setup-ran").path))
        XCTAssertEqual(try SessionStore(fixture.db).forTask(task.id).first?.state.isActive, true)
    }

    func testARetryWhileAnEarlierAttemptIsStillSettingUpIsRefused() async throws {
        let gate = try installGatedHook(then: "echo 'setup: build server socket closed' >&2; exit 1")
        let task = try makeTask()
        let first = try await fixture.supervisor.spawnWorker(taskId: task.id)
        try await fixture.supervisor.stop(sessionId: first.setupSessionId)

        do {
            _ = try await fixture.supervisor.spawnWorker(taskId: task.id)
            XCTFail("a retry adopted a worktree whose first attempt was still in its post-checkout hook")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("still setting up"), error.localizedDescription)
        }
        FileManager.default.createFile(atPath: gate.path, contents: nil)
        await fixture.supervisor.waitForSetup()

        _ = try await fixture.supervisor.spawnWorker(taskId: task.id)
    }

    // MARK: - Helpers

    private func makeTask() throws -> BoardTask {
        try fixture.tasks.create(
            projectId: fixture.project.id, title: "Do the thing", body: "Do it.",
            acceptance: "It works.", priority: nil, column: .ready, origin: .human, epicId: nil
        )
    }

    /// The hook runs only on a new worktree's checkout (`$3` is 1 for a branch checkout).
    private func installHook(_ body: String) throws {
        let hook = fixture.repo.appendingPathComponent(".git/hooks/post-checkout")
        try FileManager.default.createDirectory(at: hook.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n[ \"$3\" = \"1\" ] || exit 0\n\(body)\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
    }

    /// Blocks the first checkout's hook until the returned file exists, or for 30 seconds, so a
    /// spawn that waits for the hook fails its assertion instead of hanging.
    private func installGatedHook(then finish: String) throws -> URL {
        let gate = fixture.supportDir.appendingPathComponent("hook-gate")
        let used = fixture.supportDir.appendingPathComponent("hook-used")
        try installHook("""
        if [ ! -e '\(used.path)' ]; then
          touch '\(used.path)'
          i=0; while [ ! -e '\(gate.path)' ] && [ $i -lt 300 ]; do sleep 0.1; i=$((i+1)); done
          \(finish)
        fi
        touch setup-ran
        """)
        return gate
    }
}
