import AgentBoardCore
import AgentBoardRuntime
import Foundation
import XCTest
@testable import AgentBoard

/// Every case runs against a real git repository: a worker running in the project's own checkout
/// is exactly the case a mocked filesystem would not catch.
@MainActor
final class SharedCheckoutSpawnTests: XCTestCase {
    private var fixture: SupervisorFixture!

    override func setUp() async throws {
        fixture = try SupervisorFixture.make(gitRepo: true)
        await fixture.supervisor.start()
        try XCTSkipIf(fixture.supervisor.serverPort == nil, "the board server could not bind a port")
    }

    override func tearDown() async throws {
        await fixture.supervisor.waitForSetup()
        fixture.cleanUp()
        fixture = nil
    }

    private func makeTask(_ title: String = "Do the thing", epicId: String? = nil) throws -> BoardTask {
        try fixture.tasks.create(
            projectId: fixture.project.id, title: title, body: "Do it.", acceptance: "It works.",
            priority: nil, column: .ready, origin: .human, epicId: epicId
        )
    }

    @discardableResult
    private func git(_ args: [String]) throws -> String {
        try SupervisorFixture.git(args, cwd: fixture.repo)
    }

    private func trimmed(_ output: String) -> String {
        output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func repoBranch() throws -> String {
        trimmed(try git(["rev-parse", "--abbrev-ref", "HEAD"]))
    }

    private func head(_ ref: String) throws -> String {
        trimmed(try git(["rev-parse", ref]))
    }

    private func session(of task: BoardTask) throws -> AgentSession {
        try XCTUnwrap(fixture.sessions.forTask(task.id).last)
    }

    private func setWorktreeRoot(_ path: String) throws {
        let projectId = fixture.project.id
        try fixture.db.writer.write { db in
            try db.execute(sql: "UPDATE project SET worktree_root = ? WHERE id = ?", arguments: [path, projectId])
        }
    }

    private func assign(_ task: BoardTask) async throws {
        try await fixture.supervisor.assign(taskId: task.id)
        await fixture.supervisor.waitForSetup()
    }

    // MARK: - shared

    func testASharedWorkerRunsInTheProjectCheckoutWithNoWorktree() async throws {
        try fixture.setWorktreeStrategy(.shared)
        let task = try makeTask()

        try await assign(task)

        let session = try session(of: task)
        XCTAssertNil(session.worktreePath, "a shared worker recorded a worktree")
        XCTAssertEqual(session.cwd, fixture.project.repoPath)
        XCTAssertEqual(session.branch, "agentboard/shared")
        XCTAssertEqual(try repoBranch(), "agentboard/shared")

        let spawns = await fixture.runtime.spawns
        let request = try XCTUnwrap(spawns.last)
        XCTAssertEqual(request.cwd.resolvingSymlinksInPath().path, fixture.repo.resolvingSymlinksInPath().path)
        XCTAssertFalse(request.prompt.contains("dedicated git worktree"), request.prompt)
        XCTAssertTrue(request.prompt.contains("project's own checkout at `\(fixture.repo.path)`"), request.prompt)
        XCTAssertTrue(request.prompt.contains("shared branch `agentboard/shared`"), request.prompt)
        XCTAssertTrue(request.prompt.contains("commit_my_work"), request.prompt)
    }

    /// Nothing about the deny list follows from having a worktree, so a shared worker is refused
    /// the same three shapes — and `IntegrationGuard` reads the command text, not the cwd.
    func testASharedWorkerIsStillRefusedPushesAndPullRequests() async throws {
        try fixture.setWorktreeStrategy(.shared)

        try await assign(try makeTask())

        let spawns = await fixture.runtime.spawns
        let request = try XCTUnwrap(spawns.last)
        XCTAssertEqual(request.disallowedTools, SpawnRequest.defaultDisallowedTools)
        XCTAssertTrue(request.disallowedTools.contains("Bash(git push*)"))
        XCTAssertTrue(request.prompt.contains("Do not push. Do not open a PR."), request.prompt)
    }

    func testNoWorktreeIsCreatedForASharedWorker() async throws {
        try fixture.setWorktreeStrategy(.shared)
        let task = try makeTask()

        try await assign(task)

        let listed = try fixture.manager.list()
        XCTAssertEqual(listed.count, 1, "git registered a worktree for a shared worker: \(listed.map(\.path.path))")
        XCTAssertEqual(listed.first?.path.resolvingSymlinksInPath().path, fixture.repo.resolvingSymlinksInPath().path)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: fixture.project.worktreeRoot).appendingPathComponent(task.id).path
            )
        )
        XCTAssertTrue(
            trimmed(try git(["branch", "--list", "agentboard/\(task.id)"])).isEmpty,
            "a per-task branch was cut for a shared worker"
        )
    }

    /// The shared branch is a real branch cut from the project base, and a commit made in the
    /// checkout lands on it and nowhere else.
    func testASharedWorkerCommitsOnTheSharedBranchAndLeavesTheBaseAlone() async throws {
        try fixture.setWorktreeStrategy(.shared)
        let mainBefore = try head("main")

        try await assign(try makeTask())
        XCTAssertEqual(try head("agentboard/shared"), mainBefore, "the shared branch was not cut from main")

        try "work\n".write(to: fixture.repo.appendingPathComponent("work.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."])
        try SupervisorFixture.commit("Do the work", cwd: fixture.repo)

        XCTAssertNotEqual(try head("agentboard/shared"), mainBefore)
        XCTAssertEqual(try head("main"), mainBefore, "a shared worker's commit moved the project base")
        XCTAssertEqual(try repoBranch(), "agentboard/shared")
    }

    /// The preflight judges a path `git worktree add` is about to create. Nothing is created here,
    /// so it has nothing to say — and must not leave a previous spawn's warning standing.
    func testTheWorktreePathPreflightIsSilentForASharedWorker() async throws {
        try setWorktreeRoot(fixture.supportDir.appendingPathComponent("Agent Board/worktrees").path)
        try await assign(try makeTask("Worktree first"))
        XCTAssertNotNil(fixture.supervisor.lastWorktreePathWarning, "the fixture failed to raise a warning")

        try fixture.setWorktreeStrategy(.shared)
        try await assign(try makeTask("Shared second"))

        XCTAssertNil(
            fixture.supervisor.lastWorktreePathWarning,
            "a shared spawn left the previous spawn's worktree-path warning standing"
        )
    }

    // MARK: - the group and its cap

    /// The group size is the project's, not a constant: two agents share here and the third is sent
    /// to a worktree, and neither number is the shipped default of three.
    func testTheCheckoutFillsToTheConfiguredGroupSizeAndThenIsolates() async throws {
        try fixture.setWorktreeStrategy(.shared, maxAgents: 2)
        let first = try makeTask("First")
        let second = try makeTask("Second")
        let third = try makeTask("Third")

        try await assign(first)
        try await assign(second)
        try await assign(third)

        XCTAssertNil(try session(of: first).worktreePath)
        XCTAssertNil(try session(of: second).worktreePath, "the second agent was isolated although the group had room")
        XCTAssertEqual(try session(of: second).branch, "agentboard/shared")
        let thirdSession = try session(of: third)
        let worktree = try XCTUnwrap(thirdSession.worktreePath, "a third agent moved into a full checkout")
        XCTAssertTrue(worktree.hasPrefix(fixture.project.worktreeRoot), worktree)
        XCTAssertEqual(thirdSession.branch, "agentboard/\(third.id)")
        XCTAssertEqual(thirdSession.cwd, worktree)
    }

    func testTheCheckoutIsSharedAgainOnceItsOccupantFinishes() async throws {
        try fixture.setWorktreeStrategy(.shared)
        let first = try makeTask("First")
        try await assign(first)
        try fixture.sessions.setState(try session(of: first).sessionId, .completed, endedAt: .nowMillis)

        let second = try makeTask("Second")
        try await assign(second)

        XCTAssertNil(try session(of: second).worktreePath)
        XCTAssertEqual(try session(of: second).branch, "agentboard/shared")
    }

    /// A shared branch is cut from one base, so an epic's group and a standalone group can never be
    /// the same group: they ask for different branches.
    func testAnEpicTaskSharesOnItsOwnBranchCutFromTheEpicBranch() async throws {
        try fixture.setWorktreeStrategy(.shared)
        let epic = try fixture.epics.create(projectId: fixture.project.id, title: "Epic", goal: "Ship it.")
        try git(["branch", epic.branch, "main"])
        try fixture.commitOn(branch: epic.branch, message: "Epic groundwork")
        let task = try makeTask("Epic work", epicId: epic.id)

        try await assign(task)

        let session = try session(of: task)
        XCTAssertNil(session.worktreePath)
        XCTAssertEqual(session.branch, "agentboard/shared-epic-\(epic.id)")
        XCTAssertNotEqual(session.branch, SharedCheckoutGroup.branch(epicId: nil))
        XCTAssertEqual(try head(session.branch!), try head(epic.branch), "the shared branch was not cut from the epic branch")
        XCTAssertNotEqual(try head(session.branch!), try head("main"))
    }

    func testATaskOnADifferentBaseIsNotColocated() async throws {
        try fixture.setWorktreeStrategy(.shared)
        let epic = try fixture.epics.create(projectId: fixture.project.id, title: "Epic", goal: "Ship it.")
        let epicTask = try makeTask("Epic work", epicId: epic.id)
        try await assign(epicTask)
        let group = try XCTUnwrap(try SharedCheckoutGroup.current(db: fixture.db, projectId: fixture.project.id))
        XCTAssertEqual(group.branch, SharedCheckoutGroup.branch(epicId: epic.id))

        let standalone = try makeTask("No epic here")
        XCTAssertFalse(group.admits(SharedCheckoutGroup.branch(epicId: nil)))
        try await assign(standalone)

        XCTAssertNotNil(try session(of: standalone).worktreePath, "a task on a different base joined the group")
        XCTAssertEqual(try session(of: standalone).branch, "agentboard/\(standalone.id)")
    }

    /// The group is the session rows, so a worker that outlived the app is still holding the
    /// checkout when a new supervisor comes up over the same database.
    /// Pinned to a group of one so the second spawn's placement is the assertion: if the relaunched
    /// supervisor could not see the member, the checkout would read as free and it would share.
    func testTheGroupSurvivesARelaunch() async throws {
        try fixture.setWorktreeStrategy(.shared, maxAgents: 1)
        let first = try makeTask("First")
        try await assign(first)

        let relaunched = fixture.relaunchedSupervisor()
        await relaunched.start()
        try XCTSkipIf(relaunched.serverPort == nil, "the relaunched board server could not bind a port")

        XCTAssertEqual(
            try SharedCheckoutGroup.current(db: fixture.db, projectId: fixture.project.id)?.memberSessionIds,
            [try session(of: first).sessionId]
        )
        let second = try makeTask("Second")
        try await relaunched.assign(taskId: second.id)
        await relaunched.waitForSetup()

        XCTAssertNotNil(
            try session(of: second).worktreePath,
            "after a relaunch the checkout looked free and a second agent moved in"
        )
    }

    // MARK: - what must keep working for a task with no worktree

    /// `failInterruptedSetups` runs over every `setup` row at launch. A shared row has no worktree
    /// to clean up, and must not take the project's checkout with it.
    func testFailInterruptedSetupsEndsASharedSetupRowWithoutTouchingTheCheckout() async throws {
        let task = try makeTask()
        let placeholder = try fixture.board.assign(
            taskId: task.id,
            session: AgentSession(
                sessionId: "setup-\(UUID().uuidString)",
                projectId: fixture.project.id,
                taskId: task.id,
                role: .worker,
                worktreePath: nil,
                branch: "agentboard/shared",
                cwd: fixture.project.repoPath,
                state: .setup
            )
        )

        let relaunched = fixture.relaunchedSupervisor()
        await relaunched.start()

        XCTAssertEqual(try fixture.sessions.get(placeholder.sessionId)?.state, .failed)
        XCTAssertEqual(try fixture.tasks.get(task.id)?.column, .ready)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.repo.appendingPathComponent("README.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.repo.appendingPathComponent(".git").path))
    }

    /// `WorktreeRootMigration` walks the worktrees git knows about. A shared session has none, and
    /// the project's own checkout is not under the worktree root, so nothing about it moves.
    func testTheWorktreeRootMigrationLeavesASharedSessionsCheckoutWhereItIs() async throws {
        try setWorktreeRoot(fixture.supportDir.appendingPathComponent("Agent Board/worktrees").path)
        let task = try makeTask()
        try fixture.sessions.insert(AgentSession(
            sessionId: "session-shared", projectId: fixture.project.id, taskId: task.id, role: .worker,
            worktreePath: nil, branch: "agentboard/shared", cwd: fixture.project.repoPath,
            state: .completed
        ))

        let outcome = await fixture.supervisor.migrateWorktreeRoots()

        XCTAssertEqual(outcome.skipped, [])
        XCTAssertEqual(outcome.migrated.count, 1, "\(outcome)")
        XCTAssertEqual(try fixture.sessions.get("session-shared")?.cwd, fixture.repo.path)
        XCTAssertEqual(try ProjectStore(fixture.db).get(fixture.project.id)?.repoPath, fixture.repo.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.repo.appendingPathComponent(".git").path))
    }

    /// The default path has to be what it was before this change existed.
    func testTheDefaultStrategyStillCutsAWorktree() async throws {
        XCTAssertEqual(fixture.project.settings.worktreeStrategy, .worktree)
        let task = try makeTask()

        try await assign(task)

        let session = try session(of: task)
        XCTAssertEqual(session.worktreePath, session.cwd)
        XCTAssertEqual(session.branch, "agentboard/\(task.id)")
        XCTAssertTrue(session.cwd.hasPrefix(fixture.project.worktreeRoot), session.cwd)
        XCTAssertEqual(try repoBranch(), "main", "a worktree spawn moved the project's own checkout")
    }
}
