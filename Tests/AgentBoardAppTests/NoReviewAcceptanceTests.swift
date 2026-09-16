import AgentBoardBridge
import AgentBoardCore
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
        fixture.cleanUp()
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

        // 3. worktree removal, and the merged branch with it
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree))
        XCTAssertFalse(try fixture.manager.branchExists("agentboard/\(blocker.id)"))
    }

    func testTaskReviewRunsNoneOfThoseAndLeavesTheTaskForAHuman() async throws {
        try setReviewLevel(.task)
        let subject = try task("build the parser")
        let worker = try finishedWorker(on: subject)
        let worktree = try XCTUnwrap(worker.session.worktreePath)

        let text = try await reportComplete(task: subject, session: worker.session, token: worker.token)

        XCTAssertTrue(text.contains("now in Review"), text)
        XCTAssertEqual(try fixture.tasks.get(subject.id)?.column, .review)
        let stillLive = await fixture.resolver.resolve(token: worker.token)
        XCTAssertNotNil(stillLive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree))
        XCTAssertTrue(try fixture.manager.branchExists("agentboard/\(subject.id)"))
    }

    func testAnEpicOverrideOfNoReviewAcceptsATaskTheProjectWouldHaveHeld() async throws {
        try setReviewLevel(.task)
        let epic = try fixture.epics.create(projectId: fixture.project.id, title: "Parser", goal: nil)
        try fixture.epics.setReviewLevel(epic.id, ReviewLevel.none)
        let subject = try task("lexer", epicId: epic.id)
        let worker = try finishedWorker(on: subject)

        _ = try await reportComplete(task: subject, session: worker.session, token: worker.token)

        XCTAssertEqual(try fixture.tasks.get(subject.id)?.column, .done)
        let revoked = await fixture.resolver.resolve(token: worker.token)
        XCTAssertNil(revoked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(worker.session.worktreePath)))
    }

    func testAnEpicIntegrationTaskStillWaitsForAHumanUnderNoReview() async throws {
        try setReviewLevel(.none)
        let epic = try fixture.epics.create(projectId: fixture.project.id, title: "Parser", goal: nil)
        try fixture.epics.setState(epic.id, .integrating)
        let integration = try fixture.tasks.create(
            projectId: fixture.project.id, title: "Integrate Parser", body: nil, acceptance: nil,
            priority: nil, column: .ready, origin: .integration, epicId: epic.id
        )
        let worker = try finishedWorker(on: integration)

        let text = try await reportComplete(task: integration, session: worker.session, token: worker.token)

        XCTAssertTrue(text.contains("now in Review"), text)
        XCTAssertEqual(try fixture.tasks.get(integration.id)?.column, .review)
        let integratorGrant = await fixture.resolver.resolve(token: worker.token)
        XCTAssertNotNil(integratorGrant, "the integrator's grant must survive until a person accepts")
    }
}
