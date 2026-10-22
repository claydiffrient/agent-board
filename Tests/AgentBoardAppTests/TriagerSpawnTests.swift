import AgentBoardBridge
import AgentBoardCore
import AgentBoardRuntime
import AgentBoardServer
import Foundation
import XCTest
@testable import AgentBoard

/// SPEC §13.2: the supervisor spawns a triager in a detached checkout of the PR head it fetched from
/// origin, under the triager scope and its deny list; nothing else may spawn onto its task, and the
/// checkout goes once every item has a verdict or its session ends.
@MainActor
final class TriagerSpawnTests: XCTestCase {
    private var fixture: SupervisorFixture!
    private var remote: URL!

    override func setUp() async throws {
        fixture = try SupervisorFixture.make(gitRepo: true)
        remote = fixture.supportDir.appendingPathComponent("remote.git")
        try SupervisorFixture.git(["init", "-q", "--bare", remote.path], cwd: fixture.supportDir)
        try fixture.git(["remote", "add", "origin", remote.path])
        try fixture.git(["push", "-q", "origin", "main"])
        await fixture.supervisor.start()
        try XCTSkipIf(fixture.supervisor.serverPort == nil, "the board server could not bind a port")
    }

    override func tearDown() async throws {
        await fixture.supervisor.waitForSetup()
        await fixture.cleanUp()
        fixture = nil
    }

    /// The PR head lives only on the remote, as a commit made on GitHub would.
    private func pushPullRequestHead() throws -> String {
        let clone = fixture.supportDir.appendingPathComponent("clone")
        try SupervisorFixture.git(["clone", "-q", remote.path, clone.path], cwd: fixture.supportDir)
        try SupervisorFixture.git(["checkout", "-q", "-b", "feature"], cwd: clone)
        try "change\n".write(to: clone.appendingPathComponent("feature.txt"), atomically: true, encoding: .utf8)
        try SupervisorFixture.git(["add", "feature.txt"], cwd: clone)
        try SupervisorFixture.git(
            ["-c", "user.email=test@example.com", "-c", "user.name=Test", "commit", "-q", "-m", "Feature"], cwd: clone
        )
        try SupervisorFixture.git(["push", "-q", "origin", "feature"], cwd: clone)
        return try SupervisorFixture.git(["rev-parse", "HEAD"], cwd: clone).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func watchPullRequest(head: String) throws -> PRWatch {
        try PRWatchStore(fixture.db).upsert(projectId: fixture.project.id, snapshot: PRSnapshot(
            repoOwner: "example-org", repoName: "app", number: 7, url: "https://github.com/example-org/app/pull/7",
            title: "Feature", headRef: "feature", headOid: head, baseRef: "main",
            items: [PRSnapshotItem(githubNodeId: "thread-1", kind: .thread, author: "reviewer", body: "Rename this.")]
        ))
    }

    func testATriagerRunsReadOnlyInADetachedCheckoutOfTheFetchedHeadThatGoesWhenTriageEnds() async throws {
        let head = try pushPullRequestHead()
        let watch = try watchPullRequest(head: head)

        let session = try await fixture.supervisor.spawnTriager(watchId: watch.id)
        await fixture.supervisor.waitForSetup()

        let spawns = await fixture.runtime.spawns
        let spawned = try XCTUnwrap(spawns.last)
        for denied in ["Edit", "Write", "NotebookEdit", "Bash(git commit*)", "Bash(gh *)", "Bash(*agentboard.sqlite*)"] {
            XCTAssertTrue(spawned.disallowedTools.contains(denied), denied)
        }
        let worktree = try XCTUnwrap(session.worktreePath)
        XCTAssertEqual(try SupervisorFixture.git(["rev-parse", "HEAD"], cwd: URL(fileURLWithPath: worktree))
            .trimmingCharacters(in: .whitespacesAndNewlines), head)
        XCTAssertNil(try? SupervisorFixture.git(["symbolic-ref", "-q", "HEAD"], cwd: URL(fileURLWithPath: worktree)))

        let taskId = try XCTUnwrap(session.taskId)
        let live = try XCTUnwrap(fixture.sessions.forTask(taskId).first)
        let grant = try XCTUnwrap(fixture.grants.forSession(live.sessionId).first)
        XCTAssertEqual(grant.scope, .triager)
        XCTAssertEqual(try PRWatchStore(fixture.db).triage(taskId: taskId)?.watchId, watch.id)

        try fixture.tasks.move(taskId, to: .ready)
        do {
            try await fixture.supervisor.assign(taskId: taskId)
            XCTFail("a worker was spawned onto a triage task")
        } catch {
            XCTAssertTrue("\(error)".contains("triage"), "\(error)")
        }

        let item = try XCTUnwrap(PRWatchStore(fixture.db).items(watchId: watch.id).first?.id)
        let sink = LateBoundSink()
        sink.target = fixture.supervisor
        let result = try await TriagerToolHandler(db: fixture.db, events: sink).call(
            "set_verdicts",
            arguments: .object(["verdicts": .array([.object([
                "item_id": .number(Double(item)), "verdict": .string("fix"), "approach": .string("Rename it."),
            ])])]),
            identity: try await fixture.identity(token: grant.token)
        )
        await result.afterResponse?()
        await fixture.supervisor.waitForTeardowns()
        XCTAssertEqual(try fixture.tasks.get(taskId)?.column, .done)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree), "the triage checkout outlived the triage")
    }

    private func lastSpawn() async throws -> SpawnRequest {
        let spawns = await fixture.runtime.spawns
        return try XCTUnwrap(spawns.last)
    }

    func testTheTriageRoleChoosesTheTriagersIdentityAndModel() async throws {
        let watch = try watchPullRequest(head: try pushPullRequestHead())
        var settings = fixture.project.settings
        settings.defaultModel = "project-model"
        try ProjectStore(fixture.db).updateSettings(fixture.project.id, settings)

        _ = try await fixture.supervisor.spawnTriager(watchId: watch.id)
        await fixture.supervisor.waitForSetup()
        let byDefault = try await lastSpawn()
        XCTAssertTrue(byDefault.prompt.hasPrefix("# You are triaging review feedback"), byDefault.prompt)
        XCTAssertEqual(byDefault.model, "project-model")

        let tess = try RosterStore(fixture.db).create(
            name: "Tess", role: "triager", systemPrompt: "Grade with the house lens.", model: "agent-model"
        )
        try RosterStore(fixture.db).enable(agentId: tess.id, forProject: fixture.project.id)
        settings.prFollowThrough.roles.triage = PRFollowThroughRole(rosterAgentId: tess.id)
        try ProjectStore(fixture.db).updateSettings(fixture.project.id, settings)

        _ = try await fixture.supervisor.spawnTriager(watchId: watch.id)
        await fixture.supervisor.waitForSetup()
        let rostered = try await lastSpawn()
        XCTAssertTrue(rostered.prompt.hasPrefix("# You are Tess"), rostered.prompt)
        XCTAssertTrue(rostered.prompt.contains("Grade with the house lens."))
        XCTAssertFalse(rostered.prompt.contains("# You are triaging review feedback"))
        XCTAssertEqual(rostered.model, "agent-model")

        settings.prFollowThrough.roles.triage?.model = "role-model"
        try ProjectStore(fixture.db).updateSettings(fixture.project.id, settings)
        _ = try await fixture.supervisor.spawnTriager(watchId: watch.id)
        await fixture.supervisor.waitForSetup()
        let overridden = try await lastSpawn()
        XCTAssertEqual(overridden.model, "role-model")
    }

    func testAStoppedTriageIsClosedWithoutAReportLosesItsCheckoutAndIsNeverResumedAsAWorker() async throws {
        let watch = try watchPullRequest(head: try pushPullRequestHead())
        let placeholder = try await fixture.supervisor.spawnTriager(watchId: watch.id)
        await fixture.supervisor.waitForSetup()
        let taskId = try XCTUnwrap(placeholder.taskId)
        let worktree = try XCTUnwrap(placeholder.worktreePath)
        let session = try XCTUnwrap(fixture.sessions.forTask(taskId).first)

        try await fixture.supervisor.stop(sessionId: session.sessionId)
        await fixture.supervisor.waitForTeardowns()

        XCTAssertEqual(try fixture.tasks.get(taskId)?.column, .closed)
        XCTAssertTrue(try fixture.reports.unconsumed(projectId: fixture.project.id).filter { $0.taskId == taskId }.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree), "a stopped triage kept its checkout")

        do {
            try await fixture.supervisor.resume(sessionId: session.sessionId)
            XCTFail("a stopped triager was resumed")
        } catch {
            XCTAssertTrue("\(error)".contains("triage"), "\(error)")
        }
        XCTAssertFalse(try fixture.grants.forSession(session.sessionId).contains { $0.scope == .worker })
        let resumed = await fixture.runtime.resumed
        XCTAssertTrue(resumed.isEmpty)
    }
}
