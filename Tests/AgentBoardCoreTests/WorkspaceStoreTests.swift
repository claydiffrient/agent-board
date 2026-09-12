import Foundation
import XCTest
@testable import AgentBoardCore

extension Fixture {
    var workspaces: WorkspaceStore { WorkspaceStore(db) }

    func otherProject(_ name: String) throws -> Project {
        try projects.register(
            name: name, repoPath: "/tmp/\(name)-\(UUID().uuidString)", baseBranch: "main",
            worktreeRoot: "/tmp/\(name)-worktrees", memoryDir: nil
        )
    }
}

final class WorkspaceStoreTests: XCTestCase {
    func testCreateAppendsInOrderAndListSortsByOrdering() throws {
        let f = try Fixture.make()
        let personal = try f.workspaces.create(name: "Personal")
        let work = try f.workspaces.create(name: "Work")

        XCTAssertLessThan(personal.ordering, work.ordering)
        XCTAssertEqual(try f.workspaces.list().map(\.name), ["Personal", "Work"])
        XCTAssertEqual(try f.workspaces.get(personal.id), personal)
        XCTAssertNil(try f.workspaces.get("missing"))
    }

    func testRenameChangesTheNameAndThrowsForUnknownWorkspace() throws {
        let f = try Fixture.make()
        let workspace = try f.workspaces.create(name: "Personal")
        try f.workspaces.rename(workspace.id, to: "Side Projects")

        XCTAssertEqual(try f.workspaces.get(workspace.id)?.name, "Side Projects")
        XCTAssertThrowsError(try f.workspaces.rename("missing", to: "x")) { error in
            XCTAssertEqual(error as? BoardError, .workspaceNotFound("missing"))
        }
    }

    func testSetOrderingReordersTheList() throws {
        let f = try Fixture.make()
        let personal = try f.workspaces.create(name: "Personal")
        let work = try f.workspaces.create(name: "Work")

        try f.workspaces.setOrdering(work.id, personal.ordering - 1)
        XCTAssertEqual(try f.workspaces.list().map(\.name), ["Work", "Personal"])

        XCTAssertThrowsError(try f.workspaces.setOrdering("missing", 3)) { error in
            XCTAssertEqual(error as? BoardError, .workspaceNotFound("missing"))
        }
    }

    func testAssignAndUnassignMoveTheProject() throws {
        let f = try Fixture.make()
        let workspace = try f.workspaces.create(name: "Personal")

        XCTAssertNil(try f.projects.get(f.project.id)?.workspaceId)
        try f.workspaces.assign(projectId: f.project.id, workspaceId: workspace.id)
        XCTAssertEqual(try f.projects.get(f.project.id)?.workspaceId, workspace.id)

        try f.workspaces.assign(projectId: f.project.id, workspaceId: nil)
        XCTAssertNil(try f.projects.get(f.project.id)?.workspaceId)
    }

    func testAssignRejectsUnknownProjectOrWorkspace() throws {
        let f = try Fixture.make()
        let workspace = try f.workspaces.create(name: "Personal")

        XCTAssertThrowsError(try f.workspaces.assign(projectId: "missing", workspaceId: workspace.id)) { error in
            XCTAssertEqual(error as? BoardError, .projectNotFound("missing"))
        }
        XCTAssertThrowsError(try f.workspaces.assign(projectId: f.project.id, workspaceId: "missing")) { error in
            XCTAssertEqual(error as? BoardError, .workspaceNotFound("missing"))
        }
        XCTAssertNil(try f.projects.get(f.project.id)?.workspaceId)
    }

    func testDeleteLeavesItsProjectsPresentAndUngrouped() throws {
        let f = try Fixture.make()
        let workspace = try f.workspaces.create(name: "Personal")
        let second = try f.otherProject("clayd-dev")
        try f.workspaces.assign(projectId: f.project.id, workspaceId: workspace.id)
        try f.workspaces.assign(projectId: second.id, workspaceId: workspace.id)

        try f.workspaces.delete(workspace.id)

        XCTAssertEqual(try f.workspaces.list(), [])
        let remaining = try f.projects.list()
        XCTAssertEqual(Set(remaining.map(\.id)), [f.project.id, second.id])
        XCTAssertTrue(remaining.allSatisfy { $0.workspaceId == nil })
    }

    func testDeleteLeavesOtherWorkspacesAssignmentsAlone() throws {
        let f = try Fixture.make()
        let personal = try f.workspaces.create(name: "Personal")
        let work = try f.workspaces.create(name: "Work")
        let second = try f.otherProject("derivita-ui")
        try f.workspaces.assign(projectId: f.project.id, workspaceId: personal.id)
        try f.workspaces.assign(projectId: second.id, workspaceId: work.id)

        try f.workspaces.delete(personal.id)

        XCTAssertEqual(try f.workspaces.list().map(\.id), [work.id])
        XCTAssertNil(try f.projects.get(f.project.id)?.workspaceId)
        XCTAssertEqual(try f.projects.get(second.id)?.workspaceId, work.id)
    }

    func testProjectDeleteDoesNotRemoveItsWorkspace() throws {
        let f = try Fixture.make()
        let workspace = try f.workspaces.create(name: "Personal")
        try f.workspaces.assign(projectId: f.project.id, workspaceId: workspace.id)

        try f.projects.delete(f.project.id)

        XCTAssertEqual(try f.workspaces.list().map(\.id), [workspace.id])
    }

    func testObserveEmitsNewWorkspaces() throws {
        let f = try Fixture.make()
        let sawSecond = expectation(description: "saw second workspace")
        let cancellable = f.workspaces.observe().start(
            in: f.db.writer,
            onError: { XCTFail("\($0)") },
            onChange: { workspaces in
                if workspaces.map(\.name) == ["Personal", "Work"] { sawSecond.fulfill() }
            }
        )
        try f.workspaces.create(name: "Personal")
        try f.workspaces.create(name: "Work")
        wait(for: [sawSecond], timeout: 2)
        cancellable.cancel()
    }
}

final class WorkspaceMigrationTests: XCTestCase {
    func testMigrationCreatesWorkspaceTableAndProjectColumn() throws {
        let db = try AppDatabase.inMemory()
        try db.reader.read { db in
            XCTAssertTrue(try db.tableExists("workspace"))
            XCTAssertEqual(
                try db.columns(in: "workspace").map(\.name),
                ["id", "name", "ordering", "created_at"]
            )
            let projectColumns = try db.columns(in: "project")
            XCTAssertTrue(projectColumns.contains { $0.name == "workspace_id" })
            XCTAssertEqual(projectColumns.first { $0.name == "workspace_id" }?.isNotNull, false)
        }
    }

    func testWorkspaceIdMustReferenceAnExistingWorkspace() throws {
        let f = try Fixture.make()
        XCTAssertThrowsError(try f.db.writer.write { db in
            try db.execute(
                sql: "UPDATE project SET workspace_id = 'missing' WHERE id = ?",
                arguments: [f.project.id]
            )
        })
    }
}
