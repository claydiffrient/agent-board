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
}
