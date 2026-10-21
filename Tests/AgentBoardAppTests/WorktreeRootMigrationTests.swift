import AgentBoardCore
import AgentBoardRuntime
import Foundation
import XCTest
@testable import AgentBoard

@MainActor
final class WorktreeRootMigrationTests: XCTestCase {
    private var sandbox: URL!
    private var repo: URL!
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
        let oldRoot = sandbox.appendingPathComponent("Library/Application Support/AgentBoard/worktrees/\(id)")
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
        WorktreeRootMigration(db: db, worktreeBase: newBase, home: sandbox.appendingPathComponent("home"))
    }

    private func reload() throws -> Project {
        try XCTUnwrap(projects.get(project.id))
    }

    func testAnOldDefaultRootWithNoWorktreesMovesToTheCurrentDefault() throws {
        let outcome = migration.run()

        XCTAssertEqual(outcome.skipped, [], "\(outcome)")
        XCTAssertEqual(try reload().worktreeRoot, newBase.appendingPathComponent(project.id).path)
        XCTAssertTrue(migration.run().isEmpty, "the second launch was not a no-op")
    }

    func testAWorktreeGitCannotReadKeepsTheOldRoot() throws {
        let manager = WorktreeManager(
            repoPath: repo, worktreeRoot: URL(fileURLWithPath: project.worktreeRoot), attribution: .unattributable
        )
        let worktree = try manager.create(name: "task-1", branch: "agentboard/task-1", base: "main")
        let admin = try SupervisorFixture.git(["rev-parse", "--absolute-git-dir"], cwd: worktree)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let gitdir = URL(fileURLWithPath: admin).appendingPathComponent("gitdir").path
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: gitdir)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: gitdir) }

        let outcome = migration.run()

        XCTAssertEqual(outcome.migrated, [])
        XCTAssertEqual(try reload().worktreeRoot, project.worktreeRoot, "the root moved past a worktree git could not read")
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
        await fixture.cleanUp()
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

    func testALegacyRootWithAWorktreeUnderItIsKeptAndTheNoticeNamesTheWorktree() async throws {
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
            hookSettingsURL: fixture.supportDir.appendingPathComponent("no-hooks.json"),
            attribution: .unattributable
        )
        let worktree = try manager.create(name: "task-1", branch: "agentboard/task-1", base: "main")

        let outcome = await fixture.supervisor.migrateWorktreeRoots()

        XCTAssertEqual(outcome.migrated, [])
        XCTAssertEqual(try ProjectStore(fixture.db).get(id)?.worktreeRoot, legacyRoot.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path))
        let notice = try XCTUnwrap(fixture.supervisor.lastError)
        XCTAssertTrue(notice.contains("Legacy"), notice)
        XCTAssertTrue(notice.contains(worktree.resolvingSymlinksInPath().path), notice)
    }

    /// Foundation expands `~/` against the real home, so this fails unless the root is resolved
    /// against the supervisor's own `home`.
    func testATildeRootResolvesUnderTheHomeDirectory() async throws {
        var project = fixture.project
        project.worktreeRoot = "~/.agentboard/example-ui/"

        let root = fixture.supervisor.worktreeManager(for: project).worktreeRoot

        XCTAssertEqual(root.path, fixture.fakeHome.appendingPathComponent(".agentboard/example-ui").path)
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
        await fixture.supervisor.waitForSetup()

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
