import AgentBoardBridge
import AgentBoardCore
import AgentBoardRuntime
import AgentBoardServer
import Foundation
import XCTest
@testable import AgentBoard

/// SPEC §5.1: a rostered reviewer changes nothing, and what it finds goes back on the task. Real
/// supervisor, real git worktree, fake claude — the test plays the reviewer.
@MainActor
final class ReviewerIsReviewOnlyTests: XCTestCase {
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

    /// A worker that committed its work and reported, then Rita spawned on the task in `review`.
    private func taskUnderReview() async throws -> (task: BoardTask, reviewer: AgentSession, token: String) {
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

        _ = try await fixture.supervisor.assignAgent(taskId: task.id, rosterAgentId: rita.id, scope: .reviewer)
        await fixture.supervisor.waitForSetup()
        let reviewer = try XCTUnwrap(fixture.sessions.forTask(task.id).first { $0.sessionId != worker.sessionId })
        let token = try XCTUnwrap(fixture.grants.forSession(reviewer.sessionId).first).token
        return (task, reviewer, token)
    }

    private func callReviewerTool(_ name: String, _ arguments: [String: JSONValue], token: String) async throws {
        let sink = LateBoundSink()
        sink.target = fixture.supervisor
        let handler = ReviewerToolHandler(db: fixture.db, control: sink, events: sink)
        _ = try await handler.call(name, arguments: .object(arguments), identity: try await fixture.identity(token: token))
    }

    func testAReviewerThatCommitsIsRefusedAndTheTaskStaysInReview() async throws {
        let (task, reviewer, token) = try await taskUnderReview()

        let spawns = await fixture.runtime.spawns
        let spawned = try XCTUnwrap(spawns.last)
        XCTAssertFalse(spawned.prompt.contains("Commit on the current branch"), "the reviewer was told to commit")
        XCTAssertFalse(spawned.prompt.contains("report_complete"))
        XCTAssertTrue(spawned.prompt.contains("`reopen_task(findings)`"))
        for denied in ["Edit", "Write", "NotebookEdit", "Bash(git commit*)"] {
            XCTAssertTrue(spawned.disallowedTools.contains(denied), denied)
        }
        let briefing = try await BriefingResourceHandler(db: fixture.db)
            .read(BriefingResourceURI.reviewer, identity: try await fixture.identity(token: token))
        XCTAssertEqual(briefing.first?.text, spawned.prompt, "the reviewer briefing drifted from the spawn prompt")

        try fixture.commitInto(reviewer.cwd, file: "reviewer-fix.txt")
        do {
            try await callReviewerTool("accept_task", ["verdict": .string("I fixed it myself.")], token: token)
            XCTFail("a reviewer that committed on the branch had its accept recorded")
        } catch let error as ToolError {
            XCTAssertTrue(error.message.contains("HEAD moved"), error.message)
        }

        XCTAssertEqual(try fixture.tasks.get(task.id)?.column, .review)
        let notes = try ProgressStore(fixture.db).list(taskId: task.id).map(\.text)
        XCTAssertFalse(notes.contains { $0.hasPrefix(Board.reviewPassedLead) })
    }

    func testReopenedFindingsReachTheNextWorkersOpeningPromptVerbatim() async throws {
        let (task, reviewer, token) = try await taskUnderReview()
        let findings = "parser.txt:1 — the test at ParserTests.swift:12 cannot fail; assert on the parsed value."

        try await callReviewerTool("reopen_task", ["findings": .string(findings)], token: token)
        XCTAssertEqual(try fixture.tasks.get(task.id)?.column, .ready)
        try fixture.sessions.setState(reviewer.sessionId, .completed)

        try await fixture.supervisor.assign(taskId: task.id)
        await fixture.supervisor.waitForSetup()
        let spawns = await fixture.runtime.spawns
        let prompt = try XCTUnwrap(spawns.last).prompt
        XCTAssertTrue(prompt.contains(findings), "the next worker never saw the reviewer's findings")
    }
}
