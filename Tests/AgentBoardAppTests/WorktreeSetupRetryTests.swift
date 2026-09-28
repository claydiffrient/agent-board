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
        fixture.cleanUp()
        fixture = nil
    }

    func testARetryAfterAFailedSetupRunsTheSetupAgain() async throws {
        let failFlag = fixture.supportDir.appendingPathComponent("fail-setup")
        FileManager.default.createFile(atPath: failFlag.path, contents: nil)
        let hook = fixture.repo.appendingPathComponent(".git/hooks/post-checkout")
        try FileManager.default.createDirectory(at: hook.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        #!/bin/sh
        [ "$3" = "1" ] || exit 0
        [ -e '\(failFlag.path)' ] && { echo "setup: bazel: command not found" >&2; exit 127; }
        touch setup-ran
        """.write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let task = try fixture.tasks.create(
            projectId: fixture.project.id, title: "Do the thing", body: "Do it.",
            acceptance: "It works.", priority: nil, column: .ready, origin: .human, epicId: nil
        )

        do {
            _ = try await fixture.supervisor.spawnWorker(taskId: task.id)
            XCTFail("the first spawn should fail in its post-checkout setup")
        } catch {
            XCTAssertTrue(String(describing: error).contains("bazel: command not found"), "\(error)")
        }
        try FileManager.default.removeItem(at: failFlag)

        let spawn = try await fixture.supervisor.spawnWorker(taskId: task.id)

        let worktree = URL(fileURLWithPath: try XCTUnwrap(spawn.worktreePath))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: worktree.appendingPathComponent("setup-ran").path),
            "the retry started a worker in a worktree whose setup never ran"
        )
    }
}
