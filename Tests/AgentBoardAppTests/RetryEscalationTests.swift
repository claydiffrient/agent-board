import AgentBoardBridge
import AgentBoardCore
import AgentBoardRuntime
import Foundation
import XCTest
@testable import AgentBoard

/// SPEC §5 retries: a task retried after a failed attempt climbs effort, then model.
@MainActor
final class RetryEscalationTests: XCTestCase {
    private var fixture: SupervisorFixture!

    override func setUp() async throws {
        fixture = try SupervisorFixture.make(gitRepo: true)
        await fixture.supervisor.start()
        try XCTSkipIf(fixture.supervisor.serverPort == nil, "the board server could not bind a port")
    }

    override func tearDown() async throws {
        await fixture.supervisor.waitForSetup()
        await fixture.cleanUp()
        fixture = nil
    }

    private func makeTask(model: String? = nil) throws -> BoardTask {
        var task = try fixture.tasks.create(
            projectId: fixture.project.id, title: "Write the tests", body: "Do it.", acceptance: nil,
            priority: nil, column: .ready, origin: .human, epicId: nil
        )
        task.type = .tests
        task.model = model
        try fixture.tasks.update(task)
        return task
    }

    private func spawn(_ taskId: String) async throws -> (spawn: WorkerSpawn, request: SpawnRequest, session: AgentSession) {
        let spawn = try await fixture.supervisor.spawnWorker(taskId: taskId)
        await fixture.supervisor.waitForSetup()
        let spawns = await fixture.runtime.spawns
        let request = try XCTUnwrap(spawns.last)
        let session = try XCTUnwrap(fixture.sessions.forTask(taskId).first)
        return (spawn, request, session)
    }

    private func failAtCap(_ session: AgentSession) throws {
        try fixture.sessions.setState(session.sessionId, .failed, endedAt: .nowMillis)
        try fixture.sessions.setStopReason(session.sessionId, "idle for 300s, over the 300s cap")
        try fixture.tasks.move(try XCTUnwrap(session.taskId), to: .ready)
    }

    func testATypeTableTaskThatFailsThreeTimesClimbsEffortThenMovesUpAModel() async throws {
        let task = try makeTask()
        var ran: [(String?, Effort?)] = []
        for _ in 1...4 {
            let attempt = try await spawn(task.id)
            ran.append((attempt.request.model, attempt.request.effort))
            if attempt.session.attempt == 2 {
                let reason = "attempt 2: effort medium → high after attempt 1 failed"
                XCTAssertEqual(attempt.session.escalation, reason)
                XCTAssertTrue(attempt.spawn.models.summary.contains(reason), attempt.spawn.models.summary)
                XCTAssertTrue(
                    try ProgressStore(fixture.db).list(taskId: task.id).contains { $0.text.contains(reason) },
                    "the escalation must reach the task's activity"
                )
            }
            try failAtCap(attempt.session)
        }

        XCTAssertEqual(ran.map(\.0), ["claude-sonnet-5-5", "claude-sonnet-5-5", "claude-sonnet-5-5", "claude-opus-5-5"])
        XCTAssertEqual(ran.map(\.1), [.medium, .high, .xhigh, .medium])
    }

    func testAnExplicitValueIsNeverEscalatedAndAHumanStopEscalatesNothing() async throws {
        let task = try makeTask(model: "claude-haiku-5-5")
        try failAtCap(try await spawn(task.id).session)

        let second = try await spawn(task.id)
        XCTAssertEqual(second.request.model, "claude-haiku-5-5", "the task's own model must survive a failure")
        XCTAssertEqual(second.request.effort, .high)

        try await fixture.supervisor.stop(sessionId: second.session.sessionId)
        try fixture.tasks.move(task.id, to: .ready)
        let third = try await spawn(task.id)
        XCTAssertEqual(third.request.effort, .high, "a human stop says nothing about the model")

        var pinned = try XCTUnwrap(fixture.tasks.get(task.id))
        pinned.effort = .low
        try fixture.tasks.update(pinned)
        try failAtCap(third.session)
        let fourth = try await spawn(task.id)
        XCTAssertEqual(fourth.request.model, "claude-haiku-5-5")
        XCTAssertEqual(fourth.request.effort, .low)
        XCTAssertNil(fourth.session.escalation)
    }
}
