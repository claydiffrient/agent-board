import AgentBoardBridge
import AgentBoardCore
import AgentBoardRuntime
import AgentBoardServer
import Foundation
import XCTest
@testable import AgentBoard

/// SPEC §5.1: a reviewer's verdict ends its session, and a reviewer whose turn ends without one is
/// raised rather than left holding the task. Real supervisor, real git worktree, fake claude.
@MainActor
final class ReviewerVerdictEndsTheReviewTests: XCTestCase {
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

    private func taskUnderReview() async throws -> (task: BoardTask, reviewer: AgentSession, rita: RosterAgent, token: String) {
        let rita = try RosterStore(fixture.db).create(
            name: "Rita", role: "reviewer", systemPrompt: "You review for correctness."
        )
        try RosterStore(fixture.db).enable(agentId: rita.id, forProject: fixture.project.id)
        let task = try fixture.tasks.create(
            projectId: fixture.project.id, title: "Add the parser", body: "Parse it.", acceptance: "Tests pass.",
            priority: nil, column: .ready, origin: .human, epicId: nil
        )
        try await fixture.supervisor.assign(taskId: task.id)
        await fixture.supervisor.waitForSetup()
        let worker = try XCTUnwrap(fixture.sessions.forTask(task.id).last)
        try fixture.commitInto(worker.cwd, file: "parser.txt")
        _ = try fixture.board.complete(taskId: task.id, sessionId: worker.sessionId, summary: "done")
        try fixture.tasks.setReviewer(task.id, rita.id)

        _ = try await fixture.supervisor.assignAgent(taskId: task.id, rosterAgentId: rita.id, scope: .reviewer)
        await fixture.supervisor.waitForSetup()
        let reviewer = try XCTUnwrap(fixture.sessions.forTask(task.id).first { $0.rosterAgentId == rita.id })
        XCTAssertTrue(reviewer.state.isActive, "the fixture must leave a live reviewer")
        let token = try XCTUnwrap(fixture.grants.forSession(reviewer.sessionId).first).token
        return (task, reviewer, rita, token)
    }

    private func failedReports() throws -> [Report] {
        try fixture.reports.unconsumed(projectId: fixture.project.id).filter { $0.kind == .failed }
    }

    func testAcceptTaskStopsTheReviewerAfterItsAnswerAndQueuesNoFailedReport() async throws {
        let (task, reviewer, _, token) = try await taskUnderReview()
        let sink = LateBoundSink()
        sink.target = fixture.supervisor
        let handler = ReviewerToolHandler(db: fixture.db, control: sink, events: sink)

        let result = try await handler.call(
            "accept_task", arguments: .object(["verdict": .string("Ran the parser tests; they pass.")]),
            identity: try await fixture.identity(token: token)
        )
        let stoppedBeforeAnswer = await fixture.runtime.stopped
        XCTAssertEqual(stoppedBeforeAnswer, [], "the reviewer was stopped before its answer was written")
        await result.afterResponse?()

        let stopped = await fixture.runtime.stopped
        XCTAssertEqual(stopped, [try XCTUnwrap(reviewer.shortId)], "the reviewer's session was left running")
        XCTAssertEqual(try fixture.sessions.get(reviewer.sessionId)?.state, .completed)
        XCTAssertEqual(try fixture.tasks.get(task.id)?.column, .done)
        XCTAssertEqual(try failedReports().map(\.body), [])
    }

    func testAReviewerWhoseTurnEndsWithoutAVerdictRaisesOneReportAndTheTaskStaysInReview() async throws {
        let (task, reviewer, rita, token) = try await taskUnderReview()
        let hooks = StoreHookSink(db: fixture.db, events: ClosureBoardEventSink())
        let identity = try await fixture.identity(token: token)
        let before = try fixture.reports.unconsumed(projectId: fixture.project.id).count

        for _ in 0..<2 {
            _ = await hooks.handle(HookEvent(name: "Stop", sessionId: reviewer.sessionId, rawJSON: "{}"), identity: identity)
        }

        let raised = try fixture.reports.unconsumed(projectId: fixture.project.id).dropFirst(before)
        XCTAssertEqual(raised.map(\.kind), [.blocked], "a reviewer that stopped without a verdict must raise exactly one report")
        XCTAssertTrue(raised.first?.body.hasPrefix(Board.reviewerStalledLead) ?? false)
        let held = try XCTUnwrap(fixture.tasks.get(task.id))
        XCTAssertEqual(held.column, .review, "nothing may accept a task its reviewer gave no verdict on")
        let hold = ReviewHold.of(
            task: held, sessions: try fixture.sessions.forTask(task.id), roster: [rita],
            progress: try ProgressStore(fixture.db).list(taskId: task.id)
        )
        XCTAssertEqual(hold.label(now: Date()), "Rita stopped without a verdict")
    }
}
