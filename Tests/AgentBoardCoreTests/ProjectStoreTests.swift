import Foundation
import XCTest
@testable import AgentBoardCore

final class ProjectStoreTests: XCTestCase {
    func testRegisterStoresDefaultsAndLooksUpByRepoPath() throws {
        let f = try Fixture.make()
        let fetched = try f.projects.byRepoPath(f.project.repoPath)
        XCTAssertEqual(fetched, f.project)
        XCTAssertEqual(fetched?.settings, ProjectSettings())
        XCTAssertEqual(fetched?.baseBranch, "main")
        XCTAssertNil(fetched?.orchSessionId)
        XCTAssertEqual(try f.projects.get(f.project.id), f.project)
        XCTAssertNil(try f.projects.byRepoPath("/nope"))
    }

    func testRepoPathIsUnique() throws {
        let f = try Fixture.make()
        XCTAssertThrowsError(
            try f.projects.register(name: "dup", repoPath: f.project.repoPath, baseBranch: "main", worktreeRoot: "/w", memoryDir: nil)
        )
    }

    func testUpdateSettingsRoundTrips() throws {
        let f = try Fixture.make()
        var settings = ProjectSettings()
        settings.caps.maxConcurrentWorkers = 1
        settings.autonomyEnabled = true
        settings.extraMcpServers = ["mdn"]
        try f.projects.updateSettings(f.project.id, settings)
        XCTAssertEqual(try f.projects.get(f.project.id)?.settings, settings)
    }

    func testOrchestratorSessionSetAndCleared() throws {
        let f = try Fixture.make()
        try f.projects.setOrchestratorSession(f.project.id, sessionId: "abc")
        XCTAssertEqual(try f.projects.get(f.project.id)?.orchSessionId, "abc")
        try f.projects.setOrchestratorSession(f.project.id, sessionId: nil)
        XCTAssertNil(try f.projects.get(f.project.id)?.orchSessionId)
    }

    func testDeleteRemovesDependentRows() throws {
        let f = try Fixture.make()
        let t = try f.task("a")
        let s = f.session(taskId: t.id)
        try f.sessions.insert(s)
        try f.tokens.issue(projectId: f.project.id, scope: .worker, taskId: t.id)
        try f.progress.append(taskId: t.id, sessionId: s.sessionId, kind: .note, text: "hi")
        try f.reports.insert(projectId: f.project.id, taskId: t.id, sessionId: s.sessionId, kind: .complete, body: "done")

        try f.projects.delete(f.project.id)

        XCTAssertNil(try f.projects.get(f.project.id))
        XCTAssertNil(try f.tasks.get(t.id))
        XCTAssertNil(try f.sessions.get(s.sessionId))
        XCTAssertEqual(try f.progress.list(taskId: t.id).count, 0)
    }

    func testObserveAllEmitsInitialValue() throws {
        let f = try Fixture.make()
        let expectation = expectation(description: "initial")
        let cancellable = f.projects.observeAll().start(
            in: f.db.writer,
            onError: { XCTFail("\($0)") },
            onChange: { projects in
                if projects.count == 1 { expectation.fulfill() }
            }
        )
        wait(for: [expectation], timeout: 2)
        cancellable.cancel()
    }
}
