import Foundation
import GRDB
import XCTest
@testable import AgentBoardCore

final class TaskArchiveTests: XCTestCase {
    func testColumnAndIndexExist() throws {
        let db = try AppDatabase.inMemory()
        try db.reader.read { db in
            XCTAssertTrue(try db.columns(in: "task").contains { $0.name == "archived_at" && !$0.isNotNull })
            let index = try XCTUnwrap(db.indexes(on: "task").first { $0.name == "task_project_archived" })
            XCTAssertEqual(index.columns, ["project_id", "archived_at"])
        }
    }

    func testArchiveUnarchiveRoundTrip() throws {
        let f = try Fixture.make()
        let task = try f.task("a", column: .done)
        XCTAssertNil(task.archivedAt)
        XCTAssertFalse(task.isArchived)

        try f.tasks.archive(task.id)
        let archived = try XCTUnwrap(f.tasks.get(task.id))
        XCTAssertTrue(archived.isArchived)
        XCTAssertGreaterThan(try XCTUnwrap(archived.archivedAt), 0)
        XCTAssertEqual(archived.column, .done)

        try f.tasks.unarchive(task.id)
        let restored = try XCTUnwrap(f.tasks.get(task.id))
        XCTAssertNil(restored.archivedAt)
        XCTAssertEqual(restored.column, .done)
    }

    func testUnarchiveIsAllowedFromAnyColumn() throws {
        let f = try Fixture.make()
        let task = try f.task("a", column: .done)
        try f.tasks.archive(task.id)
        try f.tasks.move(task.id, to: .review)
        try f.tasks.unarchive(task.id)
        XCTAssertNil(try f.tasks.get(task.id)?.archivedAt)
    }

    func testArchivingATaskOutsideDoneThrowsAndChangesNothing() throws {
        let f = try Fixture.make()
        let running = try f.task("running", column: .running)
        XCTAssertThrowsError(try f.tasks.archive(running.id)) { error in
            XCTAssertEqual(error as? BoardError, .archiveRequiresDone(taskId: running.id, column: .running))
        }
        let after = try XCTUnwrap(f.tasks.get(running.id))
        XCTAssertNil(after.archivedAt)
        XCTAssertEqual(after.column, .running)
        XCTAssertEqual(after.updatedAt, running.updatedAt)
    }

    func testBulkArchiveIsAllOrNothing() throws {
        let f = try Fixture.make()
        let first = try f.task("d1", column: .done)
        let second = try f.task("d2", column: .done)
        let review = try f.task("r", column: .review)

        XCTAssertThrowsError(try f.tasks.archive(ids: [first.id, review.id, second.id]))
        XCTAssertNil(try f.tasks.get(first.id)?.archivedAt)
        XCTAssertNil(try f.tasks.get(second.id)?.archivedAt)

        try f.tasks.archive(ids: [first.id, second.id])
        XCTAssertNotNil(try f.tasks.get(first.id)?.archivedAt)
        XCTAssertNotNil(try f.tasks.get(second.id)?.archivedAt)
        XCTAssertNil(try f.tasks.get(review.id)?.archivedAt)
    }

    func testArchivingAnUnknownTaskThrows() throws {
        let f = try Fixture.make()
        XCTAssertThrowsError(try f.tasks.archive("nope")) { error in
            XCTAssertEqual(error as? BoardError, .taskNotFound("nope"))
        }
        XCTAssertThrowsError(try f.tasks.unarchive("nope")) { error in
            XCTAssertEqual(error as? BoardError, .taskNotFound("nope"))
        }
    }

    func testListHidesArchivedByDefault() throws {
        let f = try Fixture.make()
        let open = try f.task("open", column: .done)
        let hidden = try f.task("hidden", column: .done)
        try f.tasks.archive(hidden.id)

        XCTAssertEqual(try f.tasks.list(projectId: f.project.id).map(\.id), [open.id])
        XCTAssertEqual(try f.tasks.list(projectId: f.project.id, column: .done).map(\.id), [open.id])
        XCTAssertEqual(
            Set(try f.tasks.list(projectId: f.project.id, includeArchived: true).map(\.id)),
            [open.id, hidden.id]
        )
    }

    func testListHidesArchivedWhenFilteringByEpic() throws {
        let f = try Fixture.make()
        let epic = Epic(
            id: Epic.newId(), projectId: f.project.id, title: "E", goal: nil,
            branch: "agentboard/epic-x", state: .planning, createdAt: .nowMillis
        )
        try f.db.writer.write { try epic.insert($0) }
        let member = try f.tasks.create(
            projectId: f.project.id, title: "m", body: nil, acceptance: nil, priority: nil,
            column: .done, origin: .orchestrator, epicId: epic.id
        )
        try f.tasks.archive(member.id)

        XCTAssertEqual(try f.tasks.list(projectId: f.project.id, epicId: epic.id), [])
        XCTAssertEqual(
            try f.tasks.list(projectId: f.project.id, epicId: epic.id, includeArchived: true).map(\.id),
            [member.id]
        )
    }

    func testObserveHidesArchivedByDefault() throws {
        let f = try Fixture.make()
        let task = try f.task("a", column: .done)
        let disappeared = expectation(description: "archived task drops out")
        let cancellable = f.tasks.observe(projectId: f.project.id).start(
            in: f.db.writer,
            onError: { XCTFail("\($0)") },
            onChange: { tasks in
                if tasks.isEmpty { disappeared.fulfill() }
            }
        )
        try f.tasks.archive(task.id)
        wait(for: [disappeared], timeout: 2)
        cancellable.cancel()
    }

    func testObserveIncludesArchivedWhenAsked() throws {
        let f = try Fixture.make()
        let task = try f.task("a", column: .done)
        try f.tasks.archive(task.id)
        let seen = expectation(description: "archived task still observed")
        let cancellable = f.tasks.observe(projectId: f.project.id, includeArchived: true).start(
            in: f.db.writer,
            onError: { XCTFail("\($0)") },
            onChange: { tasks in
                if tasks.map(\.id) == [task.id] { seen.fulfill() }
            }
        )
        wait(for: [seen], timeout: 2)
        cancellable.cancel()
    }

    func testArchivedDoneDependencyLeavesDependentsReady() throws {
        let f = try Fixture.make()
        let dep = try f.task("dep")
        let dependent = try f.task("dependent")
        try f.tasks.setDeps(dependent.id, dependsOn: [dep.id])
        try f.tasks.move(dep.id, to: .done)
        XCTAssertEqual(try f.tasks.refreshReadiness(projectId: f.project.id), [dependent.id])
        XCTAssertEqual(try f.tasks.get(dependent.id)?.column, .ready)

        try f.tasks.archive(dep.id)

        XCTAssertEqual(try f.tasks.refreshReadiness(projectId: f.project.id), [])
        XCTAssertEqual(try f.tasks.get(dependent.id)?.column, .ready)
        XCTAssertEqual(try f.tasks.deps(of: dependent.id), [dep.id])
    }

    func testArchivingLeavesSessionsReportsAndProgressAlone() throws {
        let f = try Fixture.make()
        let task = try f.task("a", column: .done)
        let session = AgentSession(
            sessionId: BoardId.new(), projectId: f.project.id, taskId: task.id, role: .worker,
            worktreePath: "/tmp/wt", branch: "agentboard/\(task.id)", cwd: "/tmp/wt", state: .completed
        )
        try f.sessions.insert(session)
        try f.progress.append(taskId: task.id, sessionId: session.sessionId, kind: .note, text: "worked")
        try f.reports.insert(
            projectId: f.project.id, taskId: task.id, sessionId: session.sessionId,
            kind: .complete, body: "done"
        )

        try f.tasks.archive(task.id)

        let stored = try XCTUnwrap(f.sessions.get(session.sessionId))
        XCTAssertEqual(stored.taskId, task.id)
        XCTAssertEqual(stored.worktreePath, "/tmp/wt")
        XCTAssertEqual(stored.branch, "agentboard/\(task.id)")
        XCTAssertEqual(try f.sessions.forTask(task.id).count, 1)
        XCTAssertEqual(try f.progress.list(taskId: task.id).count, 1)
        XCTAssertEqual(try f.reports.latest(taskId: task.id)?.body, "done")
        XCTAssertEqual(try f.reports.unconsumed(projectId: f.project.id).count, 1)
    }
}

final class ArchivePolicySettingsTests: XCTestCase {
    func testDefaultIsAfterEpicMerge() {
        XCTAssertEqual(ProjectSettings().archivePolicy, .afterEpicMerge)
        XCTAssertEqual(ProjectSettings.forNewProject().archivePolicy, .afterEpicMerge)
    }

    func testSettingsBlobPredatingArchiveDecodesToAfterEpicMerge() {
        let storedBeforeThisChange = #"{"autonomyEnabled":true,"caps":{"maxConcurrentWorkers":2,"maxIdleSeconds":300,"maxWallClockSeconds":1800,"stallSeconds":120},"extraMcpServers":[],"defaultModel":"claude-sonnet-5"}"#
        let settings = ProjectSettings.decode(storedBeforeThisChange)
        XCTAssertEqual(settings.archivePolicy, .afterEpicMerge)
        XCTAssertEqual(settings.caps.maxConcurrentWorkers, 2)
        XCTAssertTrue(settings.autonomyEnabled)
        XCTAssertEqual(settings.defaultModel, "claude-sonnet-5")
    }

    func testEveryPolicyRoundTrips() {
        for policy in [ArchivePolicy.manual, .afterDays(14), .afterEpicMerge] {
            var settings = ProjectSettings()
            settings.archivePolicy = policy
            XCTAssertEqual(ProjectSettings.decode(settings.encoded()).archivePolicy, policy)
        }
    }

    func testAfterDaysKeepsItsCount() throws {
        let json = #"{"archivePolicy":{"days":7,"mode":"afterDays"}}"#
        XCTAssertEqual(ProjectSettings.decode(json).archivePolicy, .afterDays(7))
    }

    func testPolicySurvivesAProjectRoundTrip() throws {
        let db = try AppDatabase.inMemory()
        let projects = ProjectStore(db)
        let project = try projects.register(
            name: "p", repoPath: "/tmp/p-\(UUID().uuidString)", baseBranch: "main",
            worktreeRoot: "/tmp/w", memoryDir: nil
        )
        XCTAssertEqual(try projects.get(project.id)?.settings.archivePolicy, .afterEpicMerge)

        var settings = try XCTUnwrap(projects.get(project.id)?.settings)
        settings.archivePolicy = .afterDays(3)
        try projects.updateSettings(project.id, settings)
        XCTAssertEqual(try projects.get(project.id)?.settings.archivePolicy, .afterDays(3))
    }
}
