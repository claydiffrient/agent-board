import AgentBoardBridge
import AgentBoardCore
import AgentBoardServer
import Foundation
import XCTest

/// SPEC §5.1: the board's own check on `report_complete`, recorded on the task before review is routed.
final class CompletionCheckTests: XCTestCase {
    private var f: BridgeFixture!
    private var task: BoardTask!
    private var worker: TokenIdentity!

    override func setUpWithError() throws {
        f = try BridgeFixture.make()
        task = try f.task("ship search", column: .ready)
        try f.board.assign(
            taskId: task.id,
            session: AgentSession(
                sessionId: "s1", shortId: "alpha", projectId: f.project.id, taskId: task.id, role: .worker,
                worktreePath: "/wt/\(task.id)", branch: "agentboard/\(task.id)", cwd: "/wt/\(task.id)", state: .running
            )
        )
        worker = f.workerIdentity(sessionId: "s1", taskId: task.id)
    }

    private func reportComplete() async throws -> ToolResult {
        try await f.call("report_complete", ["summary": .string("Wrote the query layer.")], as: worker)
    }

    func testWithNoCommandsConfiguredTheTaskRecordsNotVerifiedByTheBoard() async throws {
        _ = try await reportComplete()

        XCTAssertEqual(try f.tasks.get(task.id)?.completionCheck?.isNotVerified, true)
        XCTAssertTrue(try f.progress.list(taskId: task.id).contains { $0.text.contains(CompletionCheck.notVerifiedText) })
        let ran = await f.control.completionChecksRun
        XCTAssertTrue(ran.isEmpty)
    }

    func testAFailingCheckIsRecordedWithItsTailAndTheTaskStillGoesToItsReviewer() async throws {
        var settings = try XCTUnwrap(f.projects.get(f.project.id)).settings
        settings.reviewLevel = .agent
        settings.completionCheckCommands = ["make check"]
        try f.projects.updateSettings(f.project.id, settings)
        let agent = try f.rosterReviewer("Rowan")
        let tail = "Tests/SearchTests.swift:12: error: expected 3, got 0"
        await f.control.setCompletionCheck(CompletionCheck(
            steps: [CompletionCheck.Step(command: "make check", result: .failed, exitStatus: 1, seconds: 4, outputTail: tail)],
            startedAt: 0, finishedAt: 1
        ))

        _ = try await reportComplete()

        let stored = try XCTUnwrap(f.tasks.get(task.id))
        XCTAssertEqual(stored.column, .review)
        XCTAssertEqual(stored.completionCheck?.failure?.outputTail, tail)
        XCTAssertTrue(try f.progress.list(taskId: task.id).contains { $0.kind == .error && $0.text.contains(tail) })
        let assigned = await f.control.assigned
        XCTAssertEqual(assigned.map(\.rosterAgentId), [agent.id])
        XCTAssertEqual(assigned.first?.scope, .reviewer)
        let prompt = ReviewPrompt.compose(task: stored, branch: "agentboard/\(task.id)", base: "main")
        XCTAssertTrue(prompt.contains("Agent Board's completion check failed."))
        XCTAssertTrue(prompt.contains(tail))
    }
}
