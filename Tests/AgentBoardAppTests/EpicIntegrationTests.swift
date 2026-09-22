import AgentBoardBridge
import AgentBoardCore
import AgentBoardRuntime
import AgentBoardServer
import Foundation
import XCTest
@testable import AgentBoard

@MainActor
final class EpicIntegrationTests: XCTestCase {
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

    private func epicTask(epic: Epic, title: String) throws -> BoardTask {
        try fixture.tasks.create(
            projectId: fixture.project.id, title: title, body: nil, acceptance: nil,
            priority: nil, column: .ready, origin: .orchestrator, epicId: epic.id
        )
    }

    /// What `spawn` leaves for a task inside an epic: a worktree and a branch cut from the epic branch.
    @discardableResult
    private func epicWorker(task: BoardTask, epic: Epic) throws -> AgentSession {
        let branch = "agentboard/\(task.id)"
        let worktree = try fixture.manager.create(name: task.id, branch: branch, base: epic.branch)
        let session = AgentSession(
            sessionId: "session-\(UUID().uuidString)", shortId: "short-\(task.id.prefix(6))",
            projectId: fixture.project.id, taskId: task.id, role: .worker,
            worktreePath: worktree.path, branch: branch, cwd: worktree.path,
            state: .completed, attempt: 1
        )
        try fixture.sessions.insert(session)
        return session
    }

    private func requestIntegration(epicId: String) throws -> Approval {
        try fixture.approvals.create(
            projectId: fixture.project.id, kind: .integration, taskId: nil, epicId: epicId,
            requestedBy: "orch-session", reason: nil
        )
    }

    func testApprovalSpawnsOneIntegratorOnTheEpicBranch() async throws {
        let ready = try fixture.epicReadyForIntegration(["schema", "api"])
        let approval = try requestIntegration(epicId: ready.epic.id)

        try await fixture.supervisor.approve(approvalId: approval.id)
        await fixture.supervisor.waitForSetup()

        let spawns = await fixture.runtime.spawns
        XCTAssertEqual(spawns.count, 1, "expected exactly one integrator session")
        let request = try XCTUnwrap(spawns.first)

        let expectedWorktree = URL(fileURLWithPath: fixture.project.worktreeRoot)
            .appendingPathComponent("epic-\(ready.epic.id)")
        XCTAssertEqual(request.cwd.resolvingSymlinksInPath().path, expectedWorktree.resolvingSymlinksInPath().path)
        XCTAssertEqual(
            try fixture.git(["rev-parse", "--abbrev-ref", "HEAD"], cwd: request.cwd)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            ready.epic.branch,
            "the integration worktree is not checked out on the epic branch"
        )

        let sessions = try fixture.sessions.all(projectId: fixture.project.id)
        XCTAssertEqual(sessions.count, 1)
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.role, .worker)
        XCTAssertEqual(session.branch, ready.epic.branch)
        XCTAssertEqual(try fixture.tasks.get(XCTUnwrap(session.taskId))?.origin, .integration)
    }

    func testIntegratorGetsTheSameGuardsAsAnyWorker() async throws {
        let ready = try fixture.epicReadyForIntegration(["api"])
        let approval = try requestIntegration(epicId: ready.epic.id)

        try await fixture.supervisor.approve(approvalId: approval.id)
        await fixture.supervisor.waitForSetup()

        let request = try await onlySpawn()
        XCTAssertEqual(request.permissionMode, "auto")
        XCTAssertEqual(request.disallowedTools, SpawnRequest.defaultDisallowedTools)
        let arguments = BackgroundSessionRuntime.arguments(for: request)
        XCTAssertTrue(arguments.contains("--strict-mcp-config"), "\(arguments)")
        XCTAssertEqual(arguments.first, request.prompt, "the prompt must lead or --disallowedTools swallows it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: request.configFiles.settingsURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: request.configFiles.mcpConfigURL.path))

        let session = try XCTUnwrap(fixture.sessions.all(projectId: fixture.project.id).first)
        let grant = try XCTUnwrap(fixture.grants.forSession(session.sessionId).first)
        XCTAssertEqual(grant.scope, .worker)
        XCTAssertEqual(grant.taskId, session.taskId)
    }

    func testPromptListsTaskBranchesInDependencyOrder() async throws {
        // ui depends on api, api depends on schema.
        let ready = try fixture.epicReadyForIntegration(["ui", "schema", "api"], dependsOn: [0: [2], 2: [1]])
        let byTitle = Dictionary(uniqueKeysWithValues: ready.tasks.map { ($0.title, $0.id) })
        let approval = try requestIntegration(epicId: ready.epic.id)

        try await fixture.supervisor.approve(approvalId: approval.id)
        await fixture.supervisor.waitForSetup()

        let prompt = try await onlySpawn().prompt
        let positions = ["schema", "api", "ui"].map { title in
            prompt.range(of: "`agentboard/\(byTitle[title]!)`")?.lowerBound
        }
        XCTAssertFalse(positions.contains(where: { $0 == nil }), "a task branch is missing from the prompt:\n\(prompt)")
        XCTAssertEqual(positions.compactMap { $0 }, positions.compactMap { $0 }.sorted(), "branches are out of dependency order:\n\(prompt)")
        XCTAssertTrue(prompt.contains("1. `agentboard/\(byTitle["schema"]!)`"), prompt)
        XCTAssertTrue(prompt.contains("3. `agentboard/\(byTitle["ui"]!)`"), prompt)
    }

    func testPromptOmitsBranchesAlreadyMergedIntoTheEpicBranch() async throws {
        let ready = try fixture.epicReadyForIntegration(["schema", "api"])
        let schema = try XCTUnwrap(ready.tasks.first { $0.title == "schema" })
        let api = try XCTUnwrap(ready.tasks.first { $0.title == "api" })
        try fixture.markMerged(epic: ready.epic, branch: "agentboard/\(schema.id)")
        let approval = try requestIntegration(epicId: ready.epic.id)

        try await fixture.supervisor.approve(approvalId: approval.id)
        await fixture.supervisor.waitForSetup()

        let prompt = try await onlySpawn().prompt
        XCTAssertTrue(prompt.contains("1. `agentboard/\(api.id)` — api"), prompt)
        XCTAssertFalse(prompt.contains("1. `agentboard/\(schema.id)`"), prompt)
        XCTAssertTrue(prompt.contains("Already merged into `\(ready.epic.branch)` — skip these"), prompt)
        XCTAssertTrue(prompt.contains("- `agentboard/\(schema.id)` — schema"), prompt)
    }

    /// The whole path, against the real repository: one task's work merges into the epic branch and
    /// the reaper deletes its branch, a second commits nothing and loses its branch the same way,
    /// and a third is still outstanding. The integrator must be told those are three different
    /// things — the first is landed, not missing.
    func testPromptSeparatesLandedFromNeverCommittedWhenBothBranchesAreGone() async throws {
        let epic = try fixture.epics.create(projectId: fixture.project.id, title: "At a Glance", goal: "see it all")
        try fixture.manager.ensureBranch(epic.branch, from: "main")
        let landed = try epicTask(epic: epic, title: "count the board")
        let silent = try epicTask(epic: epic, title: "document it")
        let pending = try epicTask(epic: epic, title: "shut it down")
        let landedSession = try epicWorker(task: landed, epic: epic)
        try epicWorker(task: silent, epic: epic)
        let pendingSession = try epicWorker(task: pending, epic: epic)
        try fixture.commitInto(try XCTUnwrap(landedSession.worktreePath), file: "GlanceStore.swift")
        try fixture.commitInto(try XCTUnwrap(pendingSession.worktreePath), file: "Shutdown.swift")
        let landedHead = try fixture.git(["rev-parse", "agentboard/\(landed.id)"])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        try await fixture.supervisor.accept(taskId: landed.id)
        await fixture.supervisor.reconcile(projectId: fixture.project.id)

        XCTAssertFalse(
            try fixture.manager.branchExists("agentboard/\(landed.id)"),
            "the reaper left the merged branch, so this test is not exercising the bug"
        )
        XCTAssertFalse(try fixture.manager.branchExists("agentboard/\(silent.id)"))
        XCTAssertTrue(try fixture.manager.branchExists("agentboard/\(pending.id)"))
        XCTAssertEqual(
            try fixture.manager.refCommit(TaskBranchLedger.tipRef(taskId: landed.id)), landedHead,
            "the reaper dropped the branch without recording where it stood"
        )

        try fixture.epics.setState(epic.id, .active)
        let approval = try requestIntegration(epicId: epic.id)
        try await fixture.supervisor.approve(approvalId: approval.id)
        await fixture.supervisor.waitForSetup()

        let prompt = try await onlySpawn().prompt
        XCTAssertTrue(prompt.contains("- `agentboard/\(landed.id)` — count the board (landed as"), prompt)
        XCTAssertTrue(prompt.contains("their branches were deleted, nothing to do"), prompt)
        XCTAssertTrue(prompt.contains("- `agentboard/\(silent.id)` — document it"), prompt)
        XCTAssertTrue(prompt.contains("Nothing was ever committed on them."), prompt)
        XCTAssertTrue(prompt.contains("1. `agentboard/\(pending.id)` — shut it down"), prompt)
        XCTAssertFalse(prompt.contains("1. `agentboard/\(landed.id)`"), "the landed task was handed over to be merged")
        XCTAssertFalse(
            prompt.contains("- `agentboard/\(landed.id)` — count the board\n"),
            "the landed task was still listed with nothing committed on it"
        )
    }

    func testEpicMovesActiveToIntegratingOnSpawnAndToDoneOnReport() async throws {
        let ready = try fixture.epicReadyForIntegration(["api"])
        XCTAssertEqual(try fixture.epics.get(ready.epic.id)?.state, .active)
        let approval = try requestIntegration(epicId: ready.epic.id)

        try await fixture.supervisor.approve(approvalId: approval.id)
        await fixture.supervisor.waitForSetup()
        XCTAssertEqual(try fixture.epics.get(ready.epic.id)?.state, .integrating)

        let session = try XCTUnwrap(fixture.sessions.all(projectId: fixture.project.id).first)
        try await reportComplete(session: session)

        XCTAssertEqual(try fixture.epics.get(ready.epic.id)?.state, .done)
        // afterEpicMerge is the default policy: the merged epic's tasks, integration task included,
        // archive in the same transaction rather than piling up in review and done.
        let integration = try XCTUnwrap(fixture.tasks.get(XCTUnwrap(session.taskId)))
        XCTAssertEqual(integration.column, .done)
        XCTAssertTrue(integration.isArchived)
        XCTAssertTrue(try XCTUnwrap(fixture.tasks.get(ready.tasks[0].id)).isArchived)
        XCTAssertEqual(try fixture.tasks.list(projectId: fixture.project.id), [])
    }

    func testApprovingASpawnStillSpawnsTheTaskWorker() async throws {
        let task = try fixture.tasks.create(
            projectId: fixture.project.id, title: "Do the thing", body: nil, acceptance: nil,
            priority: nil, column: .ready, origin: .human, epicId: nil
        )
        let approval = try fixture.approvals.create(
            projectId: fixture.project.id, kind: .spawn, taskId: task.id, epicId: nil,
            requestedBy: "orch-session", reason: nil
        )

        try await fixture.supervisor.approve(approvalId: approval.id)
        await fixture.supervisor.waitForSetup()

        let spawns = await fixture.runtime.spawns
        XCTAssertEqual(spawns.count, 1)
        let request = try XCTUnwrap(spawns.first)
        XCTAssertEqual(
            request.cwd.resolvingSymlinksInPath().path,
            URL(fileURLWithPath: fixture.project.worktreeRoot).appendingPathComponent(task.id)
                .resolvingSymlinksInPath().path
        )
        XCTAssertTrue(request.prompt.hasPrefix("# Task: Do the thing"), request.prompt)
        XCTAssertEqual(try fixture.tasks.get(task.id)?.column, .running)
        XCTAssertEqual(
            try fixture.sessions.all(projectId: fixture.project.id).first?.branch,
            "agentboard/\(task.id)"
        )
        XCTAssertNil(try fixture.epics.list(projectId: fixture.project.id).first)
    }

    /// Nothing on the integration path may reach a remote (D8, §5.2 step 4).
    func testIntegrationPathNeverPushesOrOpensAPullRequest() async throws {
        let ready = try fixture.epicReadyForIntegration(["api"])
        let approval = try requestIntegration(epicId: ready.epic.id)

        try await fixture.supervisor.approve(approvalId: approval.id)
        await fixture.supervisor.waitForSetup()

        let request = try await onlySpawn()
        XCTAssertTrue(request.prompt.contains("Do not push. Do not open a PR."), request.prompt)
        for denied in ["Bash(git push*)", "Bash(gh pr create*)", "Bash(gh pr merge*)"] {
            XCTAssertTrue(request.disallowedTools.contains(denied), "\(request.disallowedTools)")
        }
        XCTAssertEqual(try fixture.git(["remote"]).trimmingCharacters(in: .whitespacesAndNewlines), "")
        XCTAssertEqual(
            try fixture.git(["rev-parse", ready.epic.branch]),
            try fixture.git(["rev-parse", "agentboard/\(ready.tasks[0].id)^"]),
            "the epic branch moved without the integrator having run"
        )
    }

    private func onlySpawn() async throws -> SpawnRequest {
        let spawns = await fixture.runtime.spawns
        XCTAssertEqual(spawns.count, 1, "expected exactly one spawned session")
        return try XCTUnwrap(spawns.first)
    }

    private func reportComplete(session: AgentSession) async throws {
        let token = try XCTUnwrap(fixture.grants.forSession(session.sessionId).first).token
        let resolved = await fixture.resolver.resolve(token: token)
        let identity = try XCTUnwrap(resolved)
        let handler = WorkerToolHandler(db: fixture.db, control: LateBoundSink(), events: LateBoundSink())
        _ = try await handler.call(
            "report_complete",
            arguments: .object([
                "summary": .string("merged every branch; swift build and swift test are green"),
                "files_changed": .array([]),
                "tests_run": .string("swift build; swift test"),
                "caveats": .string("none"),
            ]),
            identity: identity
        )
    }
}
