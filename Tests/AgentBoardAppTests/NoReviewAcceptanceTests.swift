import AgentBoardBridge
import AgentBoardCore
import AgentBoardRuntime
import AgentBoardServer
import Foundation
import XCTest
@testable import AgentBoard

/// Under no review, `report_complete` must run the same acceptance a human Accept runs — not a
/// cheaper imitation of it. These assert the three side effects that only the supervisor performs.
@MainActor
final class NoReviewAcceptanceTests: XCTestCase {
    private var fixture: SupervisorFixture!

    override func setUp() async throws {
        fixture = try SupervisorFixture.make(gitRepo: true)
    }

    override func tearDown() async throws {
        await fixture.cleanUp()
        fixture = nil
    }

    private func setReviewLevel(_ level: ReviewLevel) throws {
        var settings = fixture.project.settings
        settings.reviewLevel = level
        try ProjectStore(fixture.db).updateSettings(fixture.project.id, settings)
    }

    @discardableResult
    private func task(_ title: String, epicId: String? = nil) throws -> BoardTask {
        try fixture.tasks.create(
            projectId: fixture.project.id, title: title, body: nil, acceptance: nil, priority: nil,
            column: .ready, origin: .human, epicId: epicId
        )
    }

    /// The real MCP call a worker makes, over the real handler graph, with the supervisor behind it.
    private func reportComplete(task: BoardTask, session: AgentSession, token: String) async throws -> String {
        let sink = LateBoundSink()
        sink.target = fixture.supervisor
        let handler = WorkerToolHandler(db: fixture.db, control: sink, events: sink)
        let resolved = await fixture.resolver.resolve(token: token)
        let identity = try XCTUnwrap(resolved)
        let result = try await handler.call(
            "report_complete",
            arguments: .object([
                "summary": .string("Renamed the symbol; swift build is green."),
                "files_changed": .array([.string("Sources/Thing.swift")]),
                "tests_run": .string("swift build"),
                "caveats": .string("none"),
            ]),
            identity: identity
        )
        return result.text
    }

    /// A worker with a real worktree, a bound grant, and a commit merged into main — the state a
    /// finished task is in when it reports.
    private func finishedWorker(on task: BoardTask) throws -> (session: AgentSession, token: String) {
        let session = try fixture.worktreeWorker(task: task, state: .running)
        try fixture.commitInto(try XCTUnwrap(session.worktreePath))
        try fixture.mergeIntoBase("agentboard/\(task.id)")
        let grant = try fixture.grants.issue(projectId: fixture.project.id, scope: .worker, taskId: task.id)
        try fixture.grants.bind(token: grant.token, sessionId: session.sessionId)
        return (session, grant.token)
    }

    func testNoReviewFiresTheNewlyReadyReportTheGrantRevocationAndTheWorktreeRemoval() async throws {
        try setReviewLevel(.none)
        let blocker = try task("build the parser")
        let dependent = try task("use the parser")
        try fixture.tasks.setDeps(dependent.id, dependsOn: [blocker.id])
        try fixture.tasks.refreshReadiness(projectId: fixture.project.id)
        let worker = try finishedWorker(on: blocker)
        let worktree = try XCTUnwrap(worker.session.worktreePath)

        let text = try await reportComplete(task: blocker, session: worker.session, token: worker.token)

        XCTAssertTrue(text.contains("straight to Done"), text)
        XCTAssertEqual(try fixture.tasks.get(blocker.id)?.column, .done)

        // 1. the newly-ready announcement (task ffd9a68a)
        let decision = try XCTUnwrap(
            ReportStore(fixture.db).unconsumed(projectId: fixture.project.id).last { $0.kind == .decision }
        )
        XCTAssertTrue(decision.body.contains(dependent.id), decision.body)
        XCTAssertTrue(decision.body.contains("use the parser"), decision.body)
        XCTAssertTrue(decision.body.contains("no review"), decision.body)
        XCTAssertEqual(try fixture.tasks.get(dependent.id)?.column, .ready)

        // 2. the token revocation (task 7aa8b54f)
        let identity = await fixture.resolver.resolve(token: worker.token)
        XCTAssertNil(identity, "the worker token still resolves after an automatic accept")
        XCTAssertTrue(try XCTUnwrap(fixture.grants.forSession(worker.session.sessionId).first).isRevoked)

        // 3. worktree removal, and the merged branch with it, which run after the answer
        await fixture.supervisor.waitForTeardowns()
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree))
        XCTAssertFalse(try fixture.manager.branchExists("agentboard/\(blocker.id)"))
    }

    /// SPEC §6: landing can run repository hooks, so the answer cannot wait for it.
    func testReportCompleteAnswersWhileTheLandingIsStillInARefHook() async throws {
        try setReviewLevel(.none)
        let epic = try fixture.epics.create(projectId: fixture.project.id, title: "Ship search", goal: nil)
        try fixture.manager.ensureBranch(epic.branch, from: "main")
        let done = try task("build the parser", epicId: epic.id)
        let session = try fixture.worktreeWorker(task: done, state: .running)
        try fixture.commitInto(try XCTUnwrap(session.worktreePath))
        let grant = try fixture.grants.issue(projectId: fixture.project.id, scope: .worker, taskId: done.id)
        try fixture.grants.bind(token: grant.token, sessionId: session.sessionId)
        let gate = try fixture.installGatedHook(
            "reference-transaction", when: "[ \"$1\" = prepared ] && grep -q ' refs/heads/\(epic.branch)$'"
        )
        let tip = try fixture.git(["rev-parse", "agentboard/\(done.id)"]).trimmingCharacters(in: .whitespacesAndNewlines)

        let text = try await reportComplete(task: done, session: session, token: grant.token)

        XCTAssertTrue(text.contains("straight to Done"), text)
        XCTAssertEqual(try fixture.tasks.get(done.id)?.column, .done)
        XCTAssertFalse(
            try fixture.manager.isMerged(commit: tip, into: "refs/heads/\(epic.branch)"),
            "report_complete waited for the accepted branch to land before answering"
        )
        FileManager.default.createFile(atPath: gate.path, contents: nil)
        await fixture.supervisor.waitForTeardowns()
        XCTAssertTrue(try fixture.manager.isMerged(commit: tip, into: "refs/heads/\(epic.branch)"))
        XCTAssertEqual(try fixture.tasks.get(done.id)?.landing, .landed)
    }

    /// The accept a tool call makes stops live sessions in the background, behind the answer
    /// (`WorkerSupervisor.accept(taskId:acceptedBy:)`). When that stop fails, the task must still
    /// reach `done`, but as `.unlanded` with its worktree kept rather than landed out from under a
    /// session that may still be working in it.
    func testAToolCallAcceptWhoseBackgroundStopFailsLeavesTheTaskUnlandedWithTheWorktreeKept() async throws {
        let blocker = try task("build the parser")
        let session = try fixture.worktreeWorker(task: blocker, state: .running)
        try fixture.commitInto(try XCTUnwrap(session.worktreePath))
        let shortId = try XCTUnwrap(session.shortId)
        await fixture.runtime.failStop(shortId: shortId, FixtureError("permission denied"))
        await fixture.runtime.setListed([
            AgentInfo(id: shortId, cwd: session.cwd, kind: "bg", sessionId: session.sessionId, status: "running"),
        ])

        try await fixture.supervisor.accept(taskId: blocker.id, acceptedBy: .policy(.none))

        XCTAssertEqual(
            try fixture.tasks.get(blocker.id)?.column, .done,
            "a stop that is still pending in the background must not hold the task out of done"
        )
        await fixture.supervisor.waitForTeardowns()

        let accepted = try XCTUnwrap(try fixture.tasks.get(blocker.id))
        XCTAssertEqual(accepted.landing, .unlanded)
        XCTAssertTrue(accepted.needsLanding)
        let decision = try XCTUnwrap(
            ReportStore(fixture.db).unconsumed(projectId: fixture.project.id).first { $0.body.contains("but its branch") }
        )
        XCTAssertTrue(decision.body.contains("was not landed and its worktree was kept"), decision.body)
        XCTAssertTrue(decision.body.contains("permission denied"), decision.body)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: try XCTUnwrap(session.worktreePath)),
            "a session that could not be stopped may still be working in the checkout"
        )
    }
}
