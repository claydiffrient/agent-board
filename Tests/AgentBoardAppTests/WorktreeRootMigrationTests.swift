import AgentBoardCore
import AgentBoardRuntime
import Foundation
import XCTest
@testable import AgentBoard

/// Every case here runs against a real repository with real `git worktree add` checkouts: the bug
/// being fixed is that git's own `gitdir` bookkeeping behaves differently from a plain directory move.
@MainActor
final class WorktreeRootMigrationTests: XCTestCase {
    private var sandbox: URL!
    private var repo: URL!
    private var oldRoot: URL!
    private var newBase: URL!
    private var db: AppDatabase!
    private var projects: ProjectStore!
    private var project: Project!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-board-migration-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        repo = sandbox.appendingPathComponent("repo")
        try SupervisorFixture.initRepo(at: repo)

        db = try AppDatabase.inMemory()
        projects = ProjectStore(db)
        let id = Project.newId()
        // The literal shape of the old default: the space lives in "Application Support".
        oldRoot = sandbox.appendingPathComponent("Library/Application Support/AgentBoard/worktrees/\(id)")
        newBase = sandbox.appendingPathComponent(".agentboard/worktrees")
        project = Project(
            id: id, name: "Legacy", repoPath: repo.path, baseBranch: "main",
            worktreeRoot: oldRoot.path, memoryDir: nil, orchSessionId: nil,
            settingsJSON: ProjectSettings.forNewProject().encoded(), createdAt: .nowMillis
        )
        try db.writer.write { db in try self.project.insert(db) }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    private var migration: WorktreeRootMigration {
        WorktreeRootMigration(db: db, worktreeBase: newBase)
    }

    private var manager: WorktreeManager {
        WorktreeManager(
            repoPath: repo,
            worktreeRoot: oldRoot,
            hookSettingsURL: sandbox.appendingPathComponent("no-hooks.json")
        )
    }

    /// A worktree under the old root carrying one commit that exists on no other branch.
    @discardableResult
    private func liveWorktree(name: String) throws -> (path: URL, commit: String) {
        let path = try manager.create(name: name, branch: "agentboard/\(name)", base: "main")
        try "work\n".write(to: path.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
        try SupervisorFixture.git(["add", "."], cwd: path)
        try SupervisorFixture.commit("Work on \(name)", cwd: path)
        let commit = try manager.headCommit(worktree: path)
        return (path, commit)
    }

    private func reload() throws -> Project {
        try XCTUnwrap(projects.get(project.id))
    }

    private func worktreePaths() throws -> [String] {
        try manager.list().map { $0.path.resolvingSymlinksInPath().path }
    }

    func testLiveWorktreeIsRelocatedAndItsCommitStaysReachable() throws {
        let (oldPath, commit) = try liveWorktree(name: "task-1")
        let expected = newBase.appendingPathComponent(project.id).appendingPathComponent("task-1")

        let outcome = migration.run()

        XCTAssertEqual(outcome.migrated.count, 1, "\(outcome)")
        XCTAssertEqual(outcome.skipped, [], "\(outcome)")
        XCTAssertEqual(try reload().worktreeRoot, newBase.appendingPathComponent(project.id).path)
        XCTAssertFalse(try reload().worktreeRoot.contains(" "))

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldPath.path), "the old checkout is still there")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.appendingPathComponent("task-1.txt").path))
        XCTAssertEqual(try worktreePaths().sorted(), [expected.path, repo.path].sorted())

        // The worktree still resolves back to the repository, and the branch's commit survived.
        XCTAssertEqual(try manager.headCommit(worktree: expected), commit)
        XCTAssertEqual(
            try SupervisorFixture.git(["rev-parse", "agentboard/task-1"], cwd: repo)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            commit
        )
        XCTAssertNoThrow(try SupervisorFixture.git(["status", "--porcelain"], cwd: expected))
    }

    func testEveryLiveWorktreeUnderTheOldRootMoves() throws {
        let first = try liveWorktree(name: "task-1")
        let second = try liveWorktree(name: "task-2")

        _ = migration.run()

        let root = newBase.appendingPathComponent(project.id)
        XCTAssertEqual(
            try worktreePaths().sorted(),
            [repo.path, root.appendingPathComponent("task-1").path, root.appendingPathComponent("task-2").path].sorted()
        )
        XCTAssertEqual(try manager.headCommit(worktree: root.appendingPathComponent("task-1")), first.commit)
        XCTAssertEqual(try manager.headCommit(worktree: root.appendingPathComponent("task-2")), second.commit)
    }

    func testRunningItTwiceChangesNothingTheSecondTime() throws {
        try liveWorktree(name: "task-1")

        let first = migration.run()
        let after = try reload().worktreeRoot
        let paths = try worktreePaths().sorted()

        let second = migration.run()

        XCTAssertEqual(first.migrated.count, 1)
        XCTAssertTrue(second.isEmpty, "\(second)")
        XCTAssertEqual(try reload().worktreeRoot, after)
        XCTAssertEqual(try worktreePaths().sorted(), paths)
    }

    func testAProjectWithAnActiveSessionIsSkippedAndSaysSo() throws {
        let (oldPath, _) = try liveWorktree(name: "task-1")
        let task = try TaskStore(db).create(
            projectId: project.id, title: "Busy", body: nil, acceptance: nil,
            priority: "normal", column: .running, origin: .human, epicId: nil
        )
        try SessionStore(db).insert(
            AgentSession(
                sessionId: "session-busy", shortId: "short-1", projectId: project.id, taskId: task.id,
                role: .worker, worktreePath: oldPath.path, branch: "agentboard/task-1",
                cwd: oldPath.path, state: .running, attempt: 1
            )
        )

        let outcome = migration.run()

        XCTAssertEqual(outcome.migrated, [])
        XCTAssertEqual(outcome.skipped.count, 1, "\(outcome)")
        XCTAssertTrue(outcome.skipped[0].contains("Legacy"), outcome.skipped[0])
        XCTAssertTrue(outcome.skipped[0].contains("running"), outcome.skipped[0])
        XCTAssertEqual(try reload().worktreeRoot, oldRoot.path, "a running worker's root was moved out from under it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldPath.path))
        XCTAssertEqual(try worktreePaths().sorted(), [oldPath.path, repo.path].sorted())
    }

    func testAProjectWithNoWorktreesJustHasItsRootRewritten() throws {
        let outcome = migration.run()

        XCTAssertEqual(outcome.migrated.count, 1)
        XCTAssertEqual(try reload().worktreeRoot, newBase.appendingPathComponent(project.id).path)
        XCTAssertEqual(try worktreePaths(), [repo.path])
    }

    func testAnUntrackedDirectoryUnderTheOldRootIsLeftAloneAndReported() throws {
        let stray = oldRoot.appendingPathComponent("not-a-worktree")
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        try "keep\n".write(to: stray.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)

        let outcome = migration.run()

        XCTAssertEqual(outcome.migrated.count, 1)
        XCTAssertEqual(outcome.notices.count, 1, "\(outcome)")
        XCTAssertTrue(outcome.notices[0].contains(oldRoot.path), outcome.notices[0])
        XCTAssertTrue(FileManager.default.fileExists(atPath: stray.appendingPathComponent("keep.txt").path))
    }

    func testAProjectAlreadyOnASpaceFreeRootIsUntouched() throws {
        let already = sandbox.appendingPathComponent(".agentboard/worktrees/already")
        try db.writer.write { db in
            try db.execute(
                sql: "UPDATE project SET worktree_root = ? WHERE id = ?",
                arguments: [already.path, self.project.id]
            )
        }

        let outcome = migration.run()

        XCTAssertTrue(outcome.isEmpty, "\(outcome)")
        XCTAssertEqual(try reload().worktreeRoot, already.path)
    }
}

@MainActor
final class DefaultWorktreeRootTests: XCTestCase {
    private var fixture: SupervisorFixture!

    override func setUp() async throws {
        fixture = try SupervisorFixture.make(gitRepo: true)
        await fixture.supervisor.start()
        try XCTSkipIf(fixture.supervisor.serverPort == nil, "the board server could not bind a port")
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    func testARegisteredProjectGetsASpaceFreeRootUnderTheSupportDirOverride() async throws {
        let other = fixture.supportDir.appendingPathComponent("other-repo")
        try SupervisorFixture.initRepo(at: other)

        let project = try await fixture.supervisor.registerProject(repoPath: other, name: "Other", baseBranch: nil)

        XCTAssertFalse(project.worktreeRoot.contains(" "), project.worktreeRoot)
        XCTAssertEqual(
            project.worktreeRoot,
            fixture.worktreeBase.appendingPathComponent(project.id).path
        )
        XCTAssertTrue(
            project.worktreeRoot.hasPrefix(fixture.supportDir.path + "/"),
            "AGENTBOARD_SUPPORT_DIR did not redirect the worktree root: \(project.worktreeRoot)"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.fakeHome.appendingPathComponent(".agentboard").path),
            "a redirected run still wrote into the home directory's .agentboard"
        )
    }

    func testTheSupervisorMigratesALegacyRootAtLaunchAndReportsWhatItSkipped() async throws {
        let legacyRepo = fixture.supportDir.appendingPathComponent("legacy-repo")
        try SupervisorFixture.initRepo(at: legacyRepo)
        let id = Project.newId()
        let legacyRoot = fixture.supportDir.appendingPathComponent("Application Support/AgentBoard/worktrees/\(id)")
        let legacy = Project(
            id: id, name: "Legacy", repoPath: legacyRepo.path, baseBranch: "main",
            worktreeRoot: legacyRoot.path, memoryDir: nil, orchSessionId: nil,
            settingsJSON: ProjectSettings.forNewProject().encoded(), createdAt: .nowMillis
        )
        try await fixture.db.writer.write { db in try legacy.insert(db) }
        let manager = WorktreeManager(
            repoPath: legacyRepo, worktreeRoot: legacyRoot,
            hookSettingsURL: fixture.supportDir.appendingPathComponent("no-hooks.json")
        )
        let worktree = try manager.create(name: "task-1", branch: "agentboard/task-1", base: "main")
        try fixture.commitInto(worktree.path)
        let commit = try manager.headCommit(worktree: worktree)

        let outcome = await fixture.supervisor.migrateWorktreeRoots()

        XCTAssertEqual(outcome.migrated.count, 1, "\(outcome)")
        let moved = fixture.worktreeBase.appendingPathComponent(id).appendingPathComponent("task-1")
        XCTAssertEqual(try ProjectStore(fixture.db).get(id)?.worktreeRoot, fixture.worktreeBase.appendingPathComponent(id).path)
        XCTAssertEqual(try manager.headCommit(worktree: moved), commit)
        XCTAssertNil(fixture.supervisor.lastError, "a clean migration should not raise a notice")

        let second = await fixture.supervisor.migrateWorktreeRoots()
        XCTAssertTrue(second.isEmpty, "the second run was not a no-op: \(second)")
    }

    func testAWorkerSpawnedUnderTheOverrideCutsItsWorktreeThereAndNotUnderTheHomeDirectory() async throws {
        let other = fixture.supportDir.appendingPathComponent("spawn-repo")
        try SupervisorFixture.initRepo(at: other)
        let project = try await fixture.supervisor.registerProject(repoPath: other, name: "Spawn", baseBranch: nil)
        let task = try TaskStore(fixture.db).create(
            projectId: project.id, title: "Do it", body: nil, acceptance: nil,
            priority: "normal", column: .ready, origin: .human, epicId: nil
        )

        try await fixture.supervisor.assign(taskId: task.id)

        let session = try XCTUnwrap(try SessionStore(fixture.db).forTask(task.id).first)
        let worktree = try XCTUnwrap(session.worktreePath)
        XCTAssertFalse(worktree.contains(" "), worktree)
        XCTAssertEqual(worktree, fixture.worktreeBase.appendingPathComponent(project.id).appendingPathComponent(task.id).path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.fakeHome.appendingPathComponent(".agentboard").path),
            "a redirected run created worktrees under the home directory's .agentboard"
        )
    }
}
