import AgentBoardBridge
import AgentBoardCore
import AgentBoardRuntime
import AgentBoardServer
import Foundation
import XCTest
@testable import AgentBoard

/// SPEC §7, §10 Status: a session on a task in `done` is never set running again, whatever
/// `claude agents` or a `SessionStart` says. Real supervisor, fake claude.
@MainActor
final class SettledTaskRevivalTests: XCTestCase {
    private var fixture: SupervisorFixture!

    override func setUp() async throws {
        fixture = try SupervisorFixture.make(gitRepo: true)
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    func testADoneTasksListedSessionIsStoppedNotRevived() async throws {
        let (task, sessionId, token) = try fixture.workerAtWork()
        try fixture.sessions.setState(sessionId, .stopped, endedAt: .nowMillis)
        try fixture.tasks.move(task.id, to: .done)
        let shortId = try XCTUnwrap(fixture.sessions.get(sessionId)?.shortId)
        await fixture.runtime.listing([
            AgentInfo(id: shortId, cwd: fixture.repo.path, kind: "bg", sessionId: sessionId, status: "running"),
        ])

        await fixture.supervisor.reconcile(projectId: fixture.project.id)

        XCTAssertEqual(try fixture.sessions.get(sessionId)?.state, .stopped, "reconcile revived a done task's session")
        let stopped = await fixture.runtime.stopped
        XCTAssertEqual(stopped, [shortId], "the process on a done task was left running")
        let failed = try fixture.reports.unconsumed(projectId: fixture.project.id).filter { $0.kind == .failed }
        XCTAssertEqual(failed.map(\.body), [])

        let hooks = StoreHookSink(db: fixture.db, events: ClosureBoardEventSink())
        _ = await hooks.handle(
            HookEvent(name: "SessionStart", sessionId: sessionId, rawJSON: "{}"),
            identity: try await fixture.identity(token: token)
        )
        XCTAssertEqual(try fixture.sessions.get(sessionId)?.state, .stopped, "SessionStart revived a done task's session")
    }

    func testAnActiveRowOnASettledTaskEndsWithADecisionReportNotAFailedOne() async throws {
        let (done, doneSession, _) = try fixture.workerAtWork("Accepted already")
        try fixture.tasks.move(done.id, to: .done)
        let (ready, readySession, _) = try fixture.workerAtWork("Back in ready")
        let listing = try [doneSession, readySession].map { sessionId in
            AgentInfo(
                id: try XCTUnwrap(fixture.sessions.get(sessionId)?.shortId), cwd: fixture.repo.path,
                kind: "bg", sessionId: sessionId, status: "running"
            )
        }
        await fixture.runtime.listing(listing)

        await fixture.supervisor.reconcile(projectId: fixture.project.id)

        let reports = try fixture.reports.unconsumed(projectId: fixture.project.id)
        XCTAssertEqual(reports.filter { $0.kind == .failed }.map(\.body), [])
        for (task, sessionId) in [(done, doneSession), (ready, readySession)] {
            let settled = reports.filter {
                $0.taskId == task.id && $0.kind == .decision && $0.body.hasPrefix("Session ended after its task was settled")
            }
            XCTAssertEqual(settled.count, 1, "\(task.title): \(reports.map(\.body))")
            XCTAssertEqual(try fixture.sessions.get(sessionId)?.state, .stopped)
            XCTAssertEqual(try fixture.tasks.get(task.id)?.failed, false)
        }
    }
}
