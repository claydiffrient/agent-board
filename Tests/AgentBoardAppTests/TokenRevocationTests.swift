import AgentBoardCore
import Foundation
import XCTest
@testable import AgentBoard

@MainActor
final class TokenRevocationTests: XCTestCase {
    private var fixture: SupervisorFixture!

    override func setUp() async throws {
        fixture = try SupervisorFixture.make()
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    func testTokenIsLiveWhileTheWorkerIsWorking() async throws {
        let worker = try fixture.workerAtWork()
        let identity = await fixture.resolver.resolve(token: worker.token)
        XCTAssertEqual(identity?.sessionId, worker.sessionId)
        XCTAssertEqual(identity?.taskId, worker.task.id)
    }

    func testAcceptRevokesEveryGrantForTheTask() async throws {
        let worker = try fixture.workerAtWork()

        try await fixture.supervisor.accept(taskId: worker.task.id)

        let identity = await fixture.resolver.resolve(token: worker.token)
        XCTAssertNil(identity, "the worker token still resolves against the MCP surface after accept")
        XCTAssertTrue(try XCTUnwrap(fixture.grants.forSession(worker.sessionId).first).isRevoked)
    }

    func testAcceptRevokesGrantsFromEveryAttempt() async throws {
        let first = try fixture.workerAtWork()
        let secondSessionId = "session-\(UUID().uuidString)"
        try fixture.sessions.insert(AgentSession(
            sessionId: secondSessionId, projectId: fixture.project.id, taskId: first.task.id,
            role: .worker, cwd: fixture.supportDir.path, state: .running, attempt: 2
        ))
        let retry = try fixture.grants.issue(projectId: fixture.project.id, scope: .worker, taskId: first.task.id)
        try fixture.grants.bind(token: retry.token, sessionId: secondSessionId)

        try await fixture.supervisor.accept(taskId: first.task.id)

        let firstIdentity = await fixture.resolver.resolve(token: first.token)
        let retryIdentity = await fixture.resolver.resolve(token: retry.token)
        XCTAssertNil(firstIdentity)
        XCTAssertNil(retryIdentity)
    }

    func testStopRevokesTheSessionsGrant() async throws {
        let worker = try fixture.workerAtWork()

        try await fixture.supervisor.stop(sessionId: worker.sessionId)

        let identity = await fixture.resolver.resolve(token: worker.token)
        XCTAssertNil(identity, "the worker token still resolves against the MCP surface after stop")
    }

    func testStopLeavesOtherSessionsGrantsAlone() async throws {
        let stopping = try fixture.workerAtWork("Stopping")
        let running = try fixture.workerAtWork("Still running")

        try await fixture.supervisor.stop(sessionId: stopping.sessionId)

        let survivor = await fixture.resolver.resolve(token: running.token)
        XCTAssertEqual(survivor?.sessionId, running.sessionId)
    }

    func testDiscardRevokesEveryGrantForTheTask() async throws {
        let worker = try fixture.workerAtWork()

        try await fixture.supervisor.discard(taskId: worker.task.id)

        let identity = await fixture.resolver.resolve(token: worker.token)
        XCTAssertNil(identity, "the worker token still resolves against the MCP surface after discard")
    }

    /// Stop revokes, so resume has to mint and bind a replacement or the resumed worker has no MCP access.
    func testResumeAfterStopIssuesAUsableToken() async throws {
        let worker = try fixture.workerAtWork()
        await fixture.supervisor.start()
        try XCTSkipIf(fixture.supervisor.serverPort == nil, "the board server could not bind a port")

        try await fixture.supervisor.stop(sessionId: worker.sessionId)
        try await fixture.supervisor.resume(sessionId: worker.sessionId)

        let live = try fixture.grants.forSession(worker.sessionId).filter { !$0.isRevoked }
        XCTAssertEqual(live.count, 1)
        let identity = await fixture.resolver.resolve(token: try XCTUnwrap(live.first).token)
        XCTAssertEqual(identity?.sessionId, worker.sessionId)
        XCTAssertEqual(identity?.taskId, worker.task.id)
        XCTAssertNotEqual(live.first?.token, worker.token)
    }
}
