import AgentBoardCore
import AgentBoardRuntime
import Foundation
import XCTest
@testable import AgentBoard

/// SPEC §3.1 step 1: a branch cut from the project base starts at the remote's base when local is
/// behind it; a task in an existing epic starts at the local epic branch and fetches nothing.
@MainActor
final class RemoteBaseSpawnTests: XCTestCase {
    private var fixture: SupervisorFixture!
    private var remote: URL!

    override func setUp() async throws {
        fixture = try SupervisorFixture.make(gitRepo: true)
        remote = fixture.supportDir.appendingPathComponent("remote.git")
        try SupervisorFixture.git(["init", "-q", "--bare", remote.path], cwd: fixture.supportDir)
        try fixture.git(["remote", "add", "origin", remote.path])
        try fixture.git(["push", "-q", "origin", "main"])
        var settings = fixture.project.settings
        settings.caps.maxConcurrentWorkers = 10
        try ProjectStore(fixture.db).updateSettings(fixture.project.id, settings)
        await fixture.supervisor.start()
        try XCTSkipIf(fixture.supervisor.serverPort == nil, "the board server could not bind a port")
    }

    override func tearDown() async throws {
        await fixture.cleanUp()
        fixture = nil
    }

    func testBranchesCutFromTheBaseTakeTheRemoteWhenLocalIsBehind() async throws {
        let localMain = try head("main")
        let remoteOnly = try pushFromAnotherClone(file: "merged.txt")

        let standalone = try await spawn(epicId: nil)
        XCTAssertTrue(try contains(standalone.branch, remoteOnly), "a standalone branch was cut from stale local main")
        XCTAssertEqual(standalone.warnings, [])
        let diff = await fixture.supervisor.worktreeDiffSummary(taskId: standalone.taskId)
        XCTAssertEqual(diff?.isEmpty, true, "the diff read the remote's commit as the task's own")

        let newEpic = try fixture.epics.create(projectId: fixture.project.id, title: "New", goal: nil)
        _ = try await spawn(epicId: newEpic.id)
        XCTAssertTrue(try contains(newEpic.branch, remoteOnly), "a new epic branch was cut from stale local main")

        let oldEpic = try fixture.epics.create(projectId: fixture.project.id, title: "Old", goal: nil)
        let epicTip = try commit(on: localMain, "Epic groundwork")
        try fixture.git(["branch", oldEpic.branch, epicTip])
        _ = try pushFromAnotherClone(file: "later.txt")
        let epicTask = try await spawn(epicId: oldEpic.id)
        XCTAssertEqual(try head(epicTask.branch), epicTip, "an epic task was not cut from the local epic branch")
        XCTAssertEqual(try head(oldEpic.branch), epicTip, "an existing epic branch was moved")
        XCTAssertEqual(try head("refs/remotes/origin/main"), remoteOnly, "spawning into an existing epic fetched")

        try fixture.git(["commit", "-q", "--allow-empty", "-m", "Not pushed yet"])
        let unpushed = try head("main")
        let diverged = try await spawn(epicId: nil)
        XCTAssertEqual(try head(diverged.branch), unpushed, "a diverged local main lost its unpushed commit")

        try fixture.git(["remote", "set-url", "origin", fixture.supportDir.appendingPathComponent("gone.git").path])
        let offline = try await spawn(epicId: nil)
        XCTAssertEqual(try head(offline.branch), unpushed)
        XCTAssertTrue(offline.warnings.contains { $0.contains("Could not fetch main from origin") }, "\(offline.warnings)")

        try fixture.git(["remote", "remove", "origin"])
        let local = try await spawn(epicId: nil)
        XCTAssertEqual(try head(local.branch), unpushed)
        XCTAssertEqual(local.warnings, [])

        XCTAssertEqual(try head("main"), unpushed, "spawning moved local main")
    }

    private struct Spawned {
        var taskId: String
        var branch: String
        var warnings: [String]
    }

    private func spawn(epicId: String?) async throws -> Spawned {
        let task = try fixture.tasks.create(
            projectId: fixture.project.id, title: "Work", body: "Do it.", acceptance: "Done.",
            priority: nil, column: .ready, origin: .human, epicId: epicId
        )
        let spawn = try await fixture.supervisor.spawnWorker(taskId: task.id)
        await fixture.supervisor.waitForSetup()
        return Spawned(taskId: task.id, branch: spawn.branch, warnings: spawn.warnings)
    }

    /// The commit lands on the remote's `main` only; the project repository has never seen it.
    private func pushFromAnotherClone(file: String) throws -> String {
        let clone = fixture.supportDir.appendingPathComponent("clone-\(file)")
        try SupervisorFixture.git(["clone", "-q", remote.path, clone.path], cwd: fixture.supportDir)
        try "merged\n".write(to: clone.appendingPathComponent(file), atomically: true, encoding: .utf8)
        try SupervisorFixture.git(["add", file], cwd: clone)
        try SupervisorFixture.git(["commit", "-q", "-m", "Merged on GitHub"], cwd: clone)
        try SupervisorFixture.git(["push", "-q", "origin", "main"], cwd: clone)
        return try SupervisorFixture.git(["rev-parse", "HEAD"], cwd: clone).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func head(_ ref: String) throws -> String {
        try fixture.git(["rev-parse", ref]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A commit on top of `parent` that no local branch points at.
    private func commit(on parent: String, _ message: String) throws -> String {
        try fixture.git([
            "-c", "user.email=test@example.com", "-c", "user.name=Test",
            "commit-tree", "\(parent)^{tree}", "-p", parent, "-m", message,
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func contains(_ branch: String, _ commit: String) throws -> Bool {
        (try? fixture.git(["merge-base", "--is-ancestor", commit, branch])) != nil
    }
}
