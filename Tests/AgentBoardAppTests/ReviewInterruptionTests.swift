import AgentBoardBridge
import AgentBoardCore
import AgentBoardRuntime
import AgentBoardServer
import Foundation
import XCTest
@testable import AgentBoard

/// A human decision on a task a rostered reviewer is still reviewing, through the real supervisor.
@MainActor
final class ReviewInterruptionTests: XCTestCase {
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

    private func taskUnderReview() async throws -> (task: BoardTask, worker: AgentSession, reviewer: AgentSession) {
        let rae = try RosterStore(fixture.db).create(
            name: "Rae", role: "reviewer", systemPrompt: "You review.", model: nil, disallowedTools: []
        )
        try RosterStore(fixture.db).enable(agentId: rae.id, forProject: fixture.project.id)
        let task = try fixture.tasks.create(
            projectId: fixture.project.id, title: "Parser checks", body: "Do it.", acceptance: "It works.",
            priority: nil, column: .ready, origin: .human, epicId: nil
        )
        try await fixture.supervisor.assign(taskId: task.id)
        await fixture.supervisor.waitForSetup()
        let worker = try XCTUnwrap(fixture.sessions.forTask(task.id).first)
        try fixture.commitInto(worker.cwd)
        _ = try fixture.board.complete(taskId: task.id, sessionId: worker.sessionId, summary: "done")
        try fixture.tasks.setReviewer(task.id, rae.id)
        _ = try await fixture.supervisor.assignAgent(taskId: task.id, rosterAgentId: rae.id, scope: .reviewer)
        await fixture.supervisor.waitForSetup()
        let reviewer = try XCTUnwrap(fixture.sessions.forTask(task.id).first { $0.rosterAgentId == rae.id })
        XCTAssertTrue(reviewer.state.isActive, "the fixture must leave a live reviewer")
        XCTAssertEqual(reviewer.cwd, worker.cwd, "a reviewer runs in the worker's worktree")
        return (task, worker, reviewer)
    }

    func testAHumanAcceptStopsTheLiveReviewerBeforeItsWorktreeIsRemovedAndLandsTheTask() async throws {
        let (task, worker, reviewer) = try await taskUnderReview()
        // A checkout holding `main` would leave the work unlanded for a reason unrelated to review.
        _ = try fixture.git(["checkout", "-q", "--detach"])
        await fixture.runtime.watch(worker.cwd)

        try await fixture.supervisor.accept(taskId: task.id)

        let stopped = await fixture.runtime.stopped
        XCTAssertEqual(stopped, [try XCTUnwrap(reviewer.shortId)], "the live reviewer must be stopped")
        let existed = await fixture.runtime.watchedPathExistedAtStop
        XCTAssertEqual(existed, [true], "the reviewer must be stopped while its worktree is still on disk")
        XCTAssertFalse(FileManager.default.fileExists(atPath: worker.cwd), "the worktree is torn down afterwards")
        XCTAssertEqual(try fixture.sessions.get(reviewer.sessionId)?.state.isActive, false)
        let accepted = try XCTUnwrap(fixture.tasks.get(task.id))
        XCTAssertEqual(accepted.column, .done)
        XCTAssertEqual(accepted.landing, .landed)
    }

    func testAHumanAcceptEndsAReviewerWhoseProcessIsGoneAndLandsTheTask() async throws {
        let (task, _, reviewer) = try await taskUnderReview()
        _ = try fixture.git(["checkout", "-q", "--detach"])
        let shortId = try XCTUnwrap(reviewer.shortId)
        await fixture.runtime.failStop(shortId: shortId, FixtureError("No job matching \(shortId)"))
        await fixture.runtime.setListed([])

        try await fixture.supervisor.accept(taskId: task.id)

        XCTAssertEqual(try fixture.sessions.get(reviewer.sessionId)?.state, .stopped)
        XCTAssertEqual(try fixture.tasks.get(task.id)?.column, .done)
        XCTAssertFalse(
            fixture.supervisor.lastError?.contains("No job matching") ?? false,
            "a stop the runtime could not do on a gone agent is not an error"
        )
    }

    func testAHumanReopenEndsAStartingReviewerThatNeverGotAShortId() async throws {
        let (task, _, reviewer) = try await taskUnderReview()
        try await fixture.db.writer.write {
            try $0.execute(
                sql: "UPDATE agent_session SET short_id = NULL, state = 'starting' WHERE session_id = ?",
                arguments: [reviewer.sessionId]
            )
        }
        await fixture.runtime.setListed([])

        try await fixture.supervisor.reopen(taskId: task.id)

        XCTAssertEqual(try fixture.sessions.get(reviewer.sessionId)?.state, .stopped)
        XCTAssertEqual(try fixture.tasks.get(task.id)?.column, .ready)
    }

    func testAHumanAcceptAbortsWhenAListedReviewerRefusesToStop() async throws {
        let (task, _, reviewer) = try await taskUnderReview()
        let shortId = try XCTUnwrap(reviewer.shortId)
        await fixture.runtime.failStop(shortId: shortId, FixtureError("permission denied"))
        await fixture.runtime.setListed([
            AgentInfo(id: shortId, cwd: reviewer.cwd, kind: "bg", sessionId: reviewer.sessionId, status: "running"),
        ])

        do {
            try await fixture.supervisor.accept(taskId: task.id)
            XCTFail("a reviewer that is still running and will not stop must abort the accept")
        } catch {}

        XCTAssertEqual(try fixture.sessions.get(reviewer.sessionId)?.state.isActive, true)
        XCTAssertEqual(try fixture.tasks.get(task.id)?.column, .review)
    }

    func testAReviewersOwnAcceptTaskDoesNotStopTheReviewer() async throws {
        let (task, _, reviewer) = try await taskUnderReview()
        let handler = ReviewerToolHandler(
            db: fixture.db, control: fixture.supervisor, events: ClosureBoardEventSink()
        )
        let identity = TokenIdentity(
            token: "reviewer", scope: .reviewer, projectId: fixture.project.id,
            sessionId: reviewer.sessionId, taskId: task.id
        )

        _ = try await handler.call("accept_task", arguments: .object(["verdict": .string("Ran it.")]), identity: identity)

        let stopped = await fixture.runtime.stopped
        XCTAssertEqual(stopped, [], "the session doing the accepting must not be stopped mid-call")
        XCTAssertEqual(try fixture.tasks.get(task.id)?.column, .done)
    }
}

/// The words a Pending reviews row shows about who holds the review.
final class ReviewHoldLabelTests: XCTestCase {
    func testTheRowSaysWhoHoldsTheReview() throws {
        let db = try AppDatabase.inMemory()
        let project = try ProjectStore(db).register(
            name: "Demo", repoPath: "/tmp/demo", baseBranch: "main", worktreeRoot: "/tmp/wt", memoryDir: "/tmp/mem"
        )
        let rita = try RosterStore(db).create(
            name: "Rita", role: "reviewer", systemPrompt: "p", model: nil, disallowedTools: []
        )
        var task = try TaskStore(db).create(
            projectId: project.id, title: "t", body: nil, acceptance: nil, priority: nil,
            column: .review, origin: .human, epicId: nil
        )
        let completedAt: Int64 = 1_000_000
        let worker = AgentSession(
            sessionId: "w", projectId: project.id, taskId: task.id, role: .worker, cwd: "/tmp/wt/t",
            state: .completed, startedAt: completedAt - 60_000, endedAt: completedAt
        )
        let reviewer = AgentSession(
            sessionId: "r", projectId: project.id, taskId: task.id, role: .worker, cwd: "/tmp/wt/t",
            state: .running, startedAt: completedAt + 1_000, rosterAgentId: rita.id
        )
        let now = (completedAt + 1_000 + 4 * 60_000).asDate
        func hold(_ sessions: [AgentSession], roster: [RosterAgent] = [rita], progress: [ProgressEntry] = []) -> ReviewHold {
            ReviewHold.of(task: task, sessions: sessions, roster: roster, progress: progress)
        }

        let reason = "Agent review, but this project has no rostered agent with a reviewer role, so it needs a person."
        let routed = ProgressEntry(taskId: task.id, sessionId: nil, at: completedAt, kind: .status, text: reason)
        let waiting = hold([worker], progress: [routed])
        XCTAssertEqual(waiting.label(now: now), "Waiting on you")
        XCTAssertEqual(waiting.reason, reason)
        XCTAssertNil(waiting.interruption(accepting: true), "no live reviewer, so Accept asks nothing")

        task.reviewerAgentId = rita.id
        let reviewing = hold([worker, reviewer])
        XCTAssertEqual(reviewing.label(now: now), "Rita reviewing · 4m 00s")
        XCTAssertEqual(
            reviewing.interruption(accepting: true),
            "Rita is reviewing this task. Accepting now stops Rita's review."
        )
        XCTAssertEqual(
            reviewing.interruption(accepting: false),
            "Rita is reviewing this task. Reopening now stops Rita's review."
        )

        var ended = reviewer
        ended.state = .stopped
        let stopped = hold([ended, worker])
        XCTAssertEqual(stopped.label(now: now), "Rita stopped")
        XCTAssertNil(stopped.interruption(accepting: true))

        XCTAssertEqual(
            hold([worker, reviewer], roster: []).label(now: now), "Deleted agent reviewing · 4m 00s",
            "a reviewer gone from the roster must still label the row"
        )
    }
}
