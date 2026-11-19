import AgentBoardCore
import AgentBoardRuntime
import Foundation
import XCTest
@testable import AgentBoard

/// SPEC §15.8: a ruling reaches a blocked worker as a resume prompt, once per ruling, and never reaches
/// a session that has stopped.
@MainActor
final class RulingDeliveryTests: XCTestCase {
    private var fixture: SupervisorFixture!

    override func setUp() async throws {
        fixture = try SupervisorFixture.make(gitRepo: true)
        await fixture.supervisor.start()
        try XCTSkipIf(fixture.supervisor.serverPort == nil, "the board server could not bind a port")
    }

    override func tearDown() async throws {
        await fixture.cleanUp()
        fixture = nil
    }

    private func blockedWorker(source: BlockedSource = .worker) throws -> (task: BoardTask, sessionId: String) {
        let (task, sessionId, _) = try fixture.workerAtWork("Blocked work")
        try fixture.tasks.move(task.id, to: .running)
        try fixture.board.block(
            taskId: task.id, sessionId: sessionId, reason: "Which table should this use?", source: source
        )
        return (task, sessionId)
    }

    @discardableResult
    private func rule(_ taskId: String, _ verdict: RulingVerdict, note: String?) throws -> Ruling {
        let task = try XCTUnwrap(fixture.tasks.get(taskId))
        return try RulingStore(fixture.db).record(
            .task(taskId), question: task.blockedReason ?? "Blocked.", questionAt: task.blockedAt ?? .nowMillis,
            verdict: verdict, note: note
        )
    }

    func testEachRulingOnABlockedSessionResumesItExactlyOnceWithTheRuling() async throws {
        let worker = try blockedWorker()
        try rule(worker.task.id, .proceed, note: "Use the queue table.")

        await fixture.supervisor.deliverOwedRulings()
        await fixture.supervisor.deliverOwedRulings()

        var resumed = await fixture.runtime.resumed
        XCTAssertEqual(resumed, [worker.sessionId])
        var prompts = await fixture.runtime.resumePrompts
        XCTAssertTrue(prompts.last?.contains("Use the queue table.") == true, prompts.last ?? "")

        try fixture.board.block(
            taskId: worker.task.id, sessionId: worker.sessionId, reason: "And the index?", source: .worker
        )
        try rule(worker.task.id, .instead, note: "Skip the index for now.")
        await fixture.supervisor.deliverOwedRulings()

        resumed = await fixture.runtime.resumed
        XCTAssertEqual(resumed, [worker.sessionId, worker.sessionId])
        prompts = await fixture.runtime.resumePrompts
        let second = try XCTUnwrap(prompts.last)
        XCTAssertTrue(second.contains("Skip the index for now."), second)
        XCTAssertFalse(second.contains("Use the queue table."), "the first ruling was delivered twice")
        XCTAssertTrue(second.contains("call `report_complete`"), second)
        let logged = try ProgressStore(fixture.db).list(taskId: worker.task.id).map(\.text)
        XCTAssertEqual(logged.filter { $0.hasPrefix("Delivered the human's ruling") }.count, 2, "\(logged)")

        try fixture.board.block(
            taskId: worker.task.id, sessionId: worker.sessionId, reason: "May I drop the table?", source: .worker
        )
        try rule(worker.task.id, .hold, note: "Not until the backup lands.")
        await fixture.supervisor.deliverOwedRulings()
        prompts = await fixture.runtime.resumePrompts
        let held = try XCTUnwrap(prompts.last)
        XCTAssertTrue(held.contains("Not until the backup lands."), held)
        XCTAssertFalse(held.contains("report_complete"), "a hold told the worker to finish: \(held)")
    }

    /// Only the terminal answers a Claude Code prompt, so a resume would talk past it; the ruling waits
    /// for the session's next `PostToolUse`.
    func testAPromptBlockedSessionIsNotResumedAndItsRulingStaysOwed() async throws {
        let worker = try blockedWorker(source: .prompt)
        let ruling = try rule(worker.task.id, .proceed, note: nil)

        await fixture.supervisor.deliverOwedRulings()

        let resumed = await fixture.runtime.resumed
        XCTAssertEqual(resumed, [])
        let owed = try RulingDeliveryStore(fixture.db).claim(sessionId: worker.sessionId, via: .hook)
        XCTAssertEqual(owed.map(\.id), [ruling.id])
    }

    func testAStoppedSessionGetsNoDelivery() async throws {
        let worker = try blockedWorker()
        try fixture.sessions.setState(worker.sessionId, .stopped)
        try rule(worker.task.id, .proceed, note: nil)

        await fixture.supervisor.deliverOwedRulings()

        let resumed = await fixture.runtime.resumed
        XCTAssertEqual(resumed, [])
    }
}
