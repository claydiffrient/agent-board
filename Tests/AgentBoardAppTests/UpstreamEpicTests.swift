import AgentBoardCore
import AgentBoardRuntime
import Foundation
import XCTest
@testable import AgentBoard

/// SPEC §3.1 step 1, §5.2, §6.1: an epic built on a pull request is cut from that pull request's
/// head, refreshes from it, and publishes back onto it only while the pull request still takes it.
@MainActor
final class UpstreamEpicTests: XCTestCase {
    private var fixture: SupervisorFixture!
    private var remote: URL!
    private let headRef = "feature/widgets"
    private let url = "https://github.com/example-org/app/pull/42"

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

    func testAnUpstreamEpicIsCutFromThePullRequestsHeadAndNeverFromTheBase() async throws {
        let prHead = try pushToHead(file: "pr.txt")
        let epic = try adopt(number: 42, headRef: headRef)

        let spawned = try await spawn(in: epic)

        XCTAssertEqual(try head(epic.branch), prHead, "the epic branch was not cut from origin/\(headRef)")
        XCTAssertEqual(try head("agentboard/\(spawned)"), prHead)
        XCTAssertNotEqual(prHead, try head("main"))

        let orphan = try adopt(number: 43, headRef: "feature/missing")
        do {
            _ = try await spawn(in: orphan)
            XCTFail("a pull request head missing from origin did not refuse the spawn")
        } catch let error as SupervisorError {
            let said = error.localizedDescription
            XCTAssertTrue(said.contains("#43") && said.contains("feature/missing"), said)
        }
        XCTAssertFalse(try fixture.manager.branchExists(orphan.branch), "the epic branch fell back to the base")
    }

    func testAnApprovedPushLandsOnTheHeadRefAndIsRefusedOnceThePullRequestCloses() async throws {
        _ = try pushToHead(file: "pr.txt")
        let epic = try adopt(number: 42, headRef: headRef)
        let taskId = try await spawn(in: epic)
        let worker = try XCTUnwrap(fixture.sessions.forTask(taskId).first)
        try fixture.commitInto(try XCTUnwrap(worker.worktreePath), file: "work.txt")
        try await fixture.supervisor.accept(taskId: taskId)
        answerPullRequest(state: "OPEN")

        try await approvePush(epic)
        XCTAssertEqual(try remoteHead(headRef), try head(epic.branch), "the push did not reach refs/heads/\(headRef)")
        XCTAssertNil(try remoteHead(epic.branch), "the epic branch was published under its own name")

        let moved = try pushToHead(file: "human.txt")
        try await assertPushFails(epic)
        XCTAssertEqual(try remoteHead(headRef), moved, "a rejected push moved the remote head")
        let rejected = try XCTUnwrap(try decisions().last)
        XCTAssertTrue(rejected.contains("refresh_epic(epic_id: \"\(epic.id)\")"), rejected)

        let refreshed = try await fixture.supervisor.refreshEpic(epicId: epic.id)
        XCTAssertEqual(refreshed.merged, "origin/\(headRef)")
        XCTAssertNoThrow(try fixture.git(["merge-base", "--is-ancestor", moved, epic.branch]))

        answerPullRequest(state: "CLOSED")
        let before = try remoteHead(headRef)
        try await assertPushFails(epic)
        XCTAssertEqual(try remoteHead(headRef), before, "a push reached a closed pull request")
        let refused = try XCTUnwrap(try decisions().last)
        XCTAssertTrue(refused.contains("pull request #42") && refused.contains("closed"), refused)
    }

    private func adopt(number: Int, headRef: String) throws -> Epic {
        try fixture.epics.create(
            projectId: fixture.project.id, title: "Widgets \(number)", goal: nil,
            upstream: EpicUpstream(
                headRef: headRef,
                pullRequest: PullRequestReference(url: "https://github.com/example-org/app/pull/\(number)", number: number)
            )
        )
    }

    private func spawn(in epic: Epic) async throws -> String {
        let task = try fixture.tasks.create(
            projectId: fixture.project.id, title: "Work", body: "Do it.", acceptance: "Done.",
            priority: nil, column: .ready, origin: .human, epicId: epic.id
        )
        _ = try await fixture.supervisor.spawnWorker(taskId: task.id)
        await fixture.supervisor.waitForSetup()
        return task.id
    }

    private func assertPushFails(_ epic: Epic) async throws {
        let push = try await requestPush(epic)
        do {
            try await fixture.supervisor.approve(approvalId: push)
            XCTFail("the push was approved and succeeded")
        } catch {}
    }

    private func approvePush(_ epic: Epic) async throws {
        try await fixture.supervisor.approve(approvalId: try await requestPush(epic))
    }

    private func requestPush(_ epic: Epic) async throws -> String {
        let asked = try await fixture.callOrchestratorTool("push_branch", arguments: .object(["branch": .string(epic.branch)]))
        XCTAssertFalse(asked.isError, asked.text)
        return try XCTUnwrap(try ApprovalStore(fixture.db).pending(projectId: fixture.project.id).first { $0.kind == .push }).id
    }

    private func answerPullRequest(state: String) {
        fixture.gh.answer(
            prefix: PullRequestStateReader.upstreamArguments(url: url),
            stdout: #"{"headRefName":"\#(headRef)","isCrossRepository":false,"state":"\#(state)"}"#
        )
    }

    /// A commit only the remote's `headRef` has, as a human pushing to their pull request would make.
    private func pushToHead(file: String) throws -> String {
        let clone = fixture.supportDir.appendingPathComponent("clone-\(file)")
        try SupervisorFixture.git(["clone", "-q", remote.path, clone.path], cwd: fixture.supportDir)
        if try remoteHead(headRef) != nil {
            try SupervisorFixture.git(["checkout", "-q", headRef], cwd: clone)
        } else {
            try SupervisorFixture.git(["checkout", "-q", "-b", headRef], cwd: clone)
        }
        try "\(file)\n".write(to: clone.appendingPathComponent(file), atomically: true, encoding: .utf8)
        try SupervisorFixture.git(["add", file], cwd: clone)
        try SupervisorFixture.commit("Add \(file)", cwd: clone)
        try SupervisorFixture.git(["push", "-q", "origin", headRef], cwd: clone)
        return try SupervisorFixture.git(["rev-parse", "HEAD"], cwd: clone).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func head(_ ref: String) throws -> String {
        try fixture.git(["rev-parse", "--verify", ref]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func remoteHead(_ branch: String) throws -> String? {
        let listed = try SupervisorFixture.git(
            ["--git-dir", remote.path, "for-each-ref", "--format=%(objectname)", "refs/heads/\(branch)"],
            cwd: fixture.supportDir
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return listed.isEmpty ? nil : listed
    }

    private func decisions() throws -> [String] {
        try ReportStore(fixture.db).unconsumed(projectId: fixture.project.id).filter { $0.kind == .decision }.map(\.body)
    }
}
