import AgentBoardBridge
import AgentBoardCore
import AgentBoardRuntime
import Foundation
import XCTest
@testable import AgentBoard

/// `git worktree add` fires the repository's `post-checkout` hook, so a repository that sets a new
/// worktree up from that hook has already run its setup by the time the path exists. The preflight
/// therefore has to speak before the spawn reaches git at all.
@MainActor
final class WorktreePathPreflightTests: XCTestCase {
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

    private func readyTask() throws -> BoardTask {
        try fixture.tasks.create(
            projectId: fixture.project.id, title: "Do the thing", body: "Do it.",
            acceptance: "It works.", priority: nil, column: .ready, origin: .human, epicId: nil
        )
    }

    private func setWorktreeRoot(_ path: String) throws {
        try fixture.db.writer.write { db in
            try db.execute(
                sql: "UPDATE project SET worktree_root = ? WHERE id = ?",
                arguments: [path, fixture.project.id]
            )
        }
    }

    func testASpacedWorktreePathIsNamedInTheSpawnResult() async throws {
        let root = fixture.supportDir.appendingPathComponent("Agent Board/worktrees")
        try setWorktreeRoot(root.path)
        let task = try readyTask()

        let spawn = try await fixture.supervisor.spawnWorker(taskId: task.id)

        let warning = try XCTUnwrap(spawn.warnings.first)
        XCTAssertTrue(warning.contains(root.appendingPathComponent(task.id).path), warning)
        XCTAssertTrue(warning.contains("a space"), warning)
        XCTAssertTrue(warning.contains("without quoting"), warning)
        XCTAssertEqual(fixture.supervisor.lastWorktreePathWarning, warning)
    }

    /// The whole point of a preflight: the warning is already recorded when the spawn dies in git,
    /// which is the case where it is most needed and where nothing else survives to say it.
    func testTheWarningSurvivesASpawnThatFailsInGit() async throws {
        let root = fixture.supportDir.appendingPathComponent("Agent Board/worktrees")
        try setWorktreeRoot(root.path)
        try FileManager.default.removeItem(at: fixture.repo)
        let task = try readyTask()

        do {
            _ = try await fixture.supervisor.spawnWorker(taskId: task.id)
            XCTFail("the spawn should have failed with no repository to cut a worktree from")
        } catch {
            XCTAssertNotNil(fixture.supervisor.lastError)
        }

        let warning = try XCTUnwrap(fixture.supervisor.lastWorktreePathWarning)
        XCTAssertTrue(warning.contains(root.appendingPathComponent(task.id).path), warning)
        XCTAssertTrue(warning.contains("a space"), warning)
    }

    func testASpaceFreeWorktreePathWarnsAboutNothing() async throws {
        let task = try readyTask()

        let spawn = try await fixture.supervisor.spawnWorker(taskId: task.id)

        XCTAssertFalse(spawn.worktreePath.contains(" "), spawn.worktreePath)
        XCTAssertEqual(spawn.warnings, [])
        XCTAssertNil(fixture.supervisor.lastWorktreePathWarning)
    }
}
