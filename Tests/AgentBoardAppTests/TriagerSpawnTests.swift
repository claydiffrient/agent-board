import AgentBoardBridge
import AgentBoardCore
import AgentBoardRuntime
import AgentBoardServer
import Foundation
import XCTest
@testable import AgentBoard

/// SPEC §13.2: the supervisor spawns a triager in a detached checkout of the PR head it fetched from
/// origin, under the triager scope and its deny list; nothing else may spawn onto its task, and the
/// checkout goes once every item has a verdict.
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

    func testATriagerRunsReadOnlyInADetachedCheckoutOfTheFetchedHeadThatGoesWhenTriageEnds() async throws {
        let head = try pushPullRequestHead()
        let watch = try PRWatchStore(fixture.db).upsert(projectId: fixture.project.id, snapshot: PRSnapshot(
            repoOwner: "example-org", repoName: "app", number: 7, url: "https://github.com/example-org/app/pull/7",
            title: "Feature", headRef: "feature", headOid: head, baseRef: "main",
            items: [PRSnapshotItem(githubNodeId: "thread-1", kind: .thread, author: "reviewer", body: "Rename this.")]
        ))

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
}
