import Foundation
import GRDB
import XCTest
@testable import AgentBoardCore

final class ProjectStoreTests: XCTestCase {
    func testRegisterStoresDefaultsAndLooksUpByRepoPath() throws {
        let f = try Fixture.make()
        let fetched = try f.projects.byRepoPath(f.project.repoPath)
        XCTAssertEqual(fetched, f.project)
        XCTAssertEqual(fetched?.settings, ProjectSettings.forNewProject())
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
        try FileLockStore(f.db).acquire(projectId: f.project.id, path: "a.swift", sessionId: s.sessionId, taskId: t.id)

        try f.projects.delete(f.project.id)

        XCTAssertNil(try f.projects.get(f.project.id))
        XCTAssertNil(try f.tasks.get(t.id))
        XCTAssertNil(try f.sessions.get(s.sessionId))
        XCTAssertEqual(try f.progress.list(taskId: t.id).count, 0)
    }

    func testDeleteRemovesRowsOtherProjectsPointAtAndKeepsTheirOwn() throws {
        let f = try Fixture.make()
        let other = try f.otherProject()
        let t = try f.task("a")
        let epic = try EpicStore(f.db).create(projectId: f.project.id, title: "e", goal: nil)
        try f.sessions.insert(f.session(taskId: t.id))
        let approvals = ApprovalStore(f.db)
        try approvals.create(projectId: f.project.id, kind: .spawn, taskId: t.id, epicId: nil, requestedBy: "orchestrator", reason: nil)
        try approvals.create(projectId: f.project.id, kind: .pullRequest, taskId: t.id, epicId: nil, requestedBy: "orchestrator", reason: nil)
        try f.messages.send(fromProjectId: other.id, fromSessionId: nil, toProjectId: f.project.id, body: "hi")
        let otherNote = try f.notes.create(projectId: other.id, title: "n", sections: [("h", "b")])
        try f.notes.attach(noteId: otherNote.id, epicId: epic.id)
        let otherTask = try f.tasks.create(
            projectId: other.id, title: "b", body: nil, acceptance: nil, priority: nil,
            column: .backlog, origin: .human, epicId: nil
        )
        try f.notes.attach(noteId: otherNote.id, taskId: otherTask.id)
        try approvals.create(projectId: other.id, kind: .spawn, taskId: otherTask.id, epicId: nil, requestedBy: "orchestrator", reason: nil)
        let otherRows = """
            SELECT 'project', id FROM project WHERE id = :id
            UNION ALL SELECT 'task', id FROM task WHERE project_id = :id
            UNION ALL SELECT 'approval', id FROM approval WHERE project_id = :id
            UNION ALL SELECT 'note', id FROM note WHERE project_id = :id
            UNION ALL SELECT 'note_section', heading FROM note_section WHERE note_id = '\(otherNote.id)'
            UNION ALL SELECT 'note_link', task_id FROM note_link WHERE task_id = '\(otherTask.id)'
            """
        let before = try f.db.reader.read { try Row.fetchAll($0, sql: otherRows, arguments: ["id": other.id]) }

        try f.projects.delete(f.project.id)

        XCTAssertNil(try f.projects.get(f.project.id))
        XCTAssertEqual(try f.db.reader.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check") }, [])
        XCTAssertEqual(try f.db.reader.read { try Row.fetchAll($0, sql: otherRows, arguments: ["id": other.id]) }, before)
        XCTAssertEqual(before.count, 6)
    }

    func testDeletedProjectsNotesDoNotMatchANoteReusingTheirRowid() throws {
        let f = try Fixture.make()
        let doomed = try f.otherProject()
        let old = try f.notes.create(projectId: doomed.id, title: "Idle cap secrets", sections: [("Why", "the idle cap kills workers")])
        let oldRowid = try rowid(f, old.id)

        try f.projects.delete(doomed.id)
        let new = try f.notes.create(projectId: f.project.id, title: "Groceries", sections: [("List", "milk")])

        XCTAssertEqual(try rowid(f, new.id), oldRowid)
        XCTAssertEqual(try f.notes.search(projectId: f.project.id, query: "idle"), [])
        XCTAssertEqual(try f.notes.search(projectId: f.project.id, query: "workers"), [])
        XCTAssertEqual(try f.notes.search(projectId: f.project.id, query: "milk").map(\.id), [new.id])
    }

    private func rowid(_ f: Fixture, _ noteId: String) throws -> Int64? {
        try f.db.reader.read { try Int64.fetchOne($0, sql: "SELECT rowid FROM note WHERE id = ?", arguments: [noteId]) }
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
