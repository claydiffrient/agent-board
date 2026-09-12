import Foundation
import GRDB
import XCTest
@testable import AgentBoardCore

private extension Fixture {
    func setPolicy(_ policy: ArchivePolicy) throws {
        var settings = try XCTUnwrap(projects.get(project.id)?.settings)
        settings.archivePolicy = policy
        try projects.updateSettings(project.id, settings)
    }

    /// A done task whose clock started `days` ago, written straight to `done_at` because nothing
    /// else can move a task into the past.
    @discardableResult
    func doneTask(_ title: String, daysInDone: Double, now: Int64 = .nowMillis) throws -> BoardTask {
        let task = try self.task(title, column: .done)
        let at = now - Int64(daysInDone * Double(ArchiveSweep.millisPerDay))
        try db.writer.write { db in
            try db.execute(sql: "UPDATE task SET done_at = ? WHERE id = ?", arguments: [at, task.id])
        }
        return try XCTUnwrap(tasks.get(task.id))
    }

    func isArchived(_ id: String) throws -> Bool {
        try XCTUnwrap(tasks.get(id)).isArchived
    }
}

final class DoneAtStampTests: XCTestCase {
    func testMovingIntoDoneStampsDoneAt() throws {
        let f = try Fixture.make()
        let task = try f.task("a")
        XCTAssertNil(task.doneAt)

        try f.tasks.move(task.id, to: .done)
        let done = try XCTUnwrap(f.tasks.get(task.id))
        XCTAssertNotNil(done.doneAt)
        XCTAssertGreaterThan(try XCTUnwrap(done.doneAt), 0)
    }

    /// The whole reason `done_at` exists: `updated_at` moves for edits that are not the move to done.
    func testDoneAtSurvivesLaterEditsThatMoveUpdatedAt() throws {
        let f = try Fixture.make()
        let task = try f.task("a")
        try f.tasks.move(task.id, to: .done)
        let entered = try XCTUnwrap(f.tasks.get(task.id)?.doneAt)

        try f.tasks.setFailed(task.id, true, reason: "flaky")
        try f.tasks.move(task.id, to: .done)

        let after = try XCTUnwrap(f.tasks.get(task.id))
        XCTAssertEqual(after.doneAt, entered)
        XCTAssertGreaterThanOrEqual(after.updatedAt, entered)
    }

    func testLeavingDoneClearsDoneAtAndTheManualUnarchiveFlag() throws {
        let f = try Fixture.make()
        let task = try f.task("a", column: .done)
        try f.tasks.archive(task.id)
        try f.tasks.unarchive(task.id)
        XCTAssertNotNil(try f.tasks.get(task.id)?.unarchivedAt)

        try f.tasks.move(task.id, to: .ready)

        let reopened = try XCTUnwrap(f.tasks.get(task.id))
        XCTAssertNil(reopened.doneAt)
        XCTAssertNil(reopened.unarchivedAt)
    }

    func testATaskCreatedDirectlyInDoneIsStamped() throws {
        let f = try Fixture.make()
        XCTAssertNotNil(try f.task("a", column: .done).doneAt)
        XCTAssertNil(try f.task("b", column: .backlog).doneAt)
    }

    func testMigrationBackfillsDoneAtFromUpdatedAt() throws {
        let db = try AppDatabase.inMemory()
        try db.reader.read { db in
            XCTAssertTrue(try db.columns(in: "task").contains { $0.name == "done_at" })
            XCTAssertTrue(try db.columns(in: "task").contains { $0.name == "unarchived_at" })
        }
    }
}

final class ArchiveSweepPolicyTests: XCTestCase {
    // MARK: - manual

    func testManualArchivesNothingOnATick() throws {
        let f = try Fixture.make()
        try f.setPolicy(.manual)
        let ancient = try f.doneTask("ancient", daysInDone: 400)

        XCTAssertEqual(try ArchiveSweep(f.db).run(projectId: f.project.id), [])
        XCTAssertFalse(try f.isArchived(ancient.id))
    }

    func testManualArchivesNothingWhenAnEpicMerges() throws {
        let f = try Fixture.make()
        try f.setPolicy(.manual)
        let merged = try f.mergeAnEpic(taskTitles: ["api"])

        for id in merged.memberIds {
            XCTAssertFalse(try f.isArchived(id))
        }
        XCTAssertFalse(try f.isArchived(merged.integrationTaskId))
        XCTAssertEqual(try f.tasks.get(merged.integrationTaskId)?.column, .review)
    }

    // MARK: - afterDays

    func testAfterDaysArchivesPastTheThresholdAndLeavesTheRest() throws {
        let f = try Fixture.make()
        try f.setPolicy(.afterDays(7))
        let old = try f.doneTask("old", daysInDone: 8)
        let young = try f.doneTask("young", daysInDone: 3)

        XCTAssertEqual(try ArchiveSweep(f.db).run(projectId: f.project.id), [old.id])
        XCTAssertTrue(try f.isArchived(old.id))
        XCTAssertFalse(try f.isArchived(young.id))
    }

    /// "More than N days in done" — at exactly N the task stays on the board, and one millisecond
    /// later it goes.
    func testAfterDaysBoundaryIsExclusive() throws {
        let f = try Fixture.make()
        try f.setPolicy(.afterDays(7))
        let now = Int64.nowMillis
        let exactly = try f.doneTask("exactly seven days in done", daysInDone: 7, now: now)
        let aHairUnder = try f.doneTask("a hair under", daysInDone: 7, now: now + 1)

        XCTAssertEqual(try ArchiveSweep(f.db).run(projectId: f.project.id, now: now), [])
        XCTAssertFalse(try f.isArchived(exactly.id))
        XCTAssertFalse(try f.isArchived(aHairUnder.id))

        XCTAssertEqual(try ArchiveSweep(f.db).run(projectId: f.project.id, now: now + 1), [exactly.id])
        XCTAssertFalse(try f.isArchived(aHairUnder.id), "still one millisecond short of seven days")

        XCTAssertEqual(try ArchiveSweep(f.db).run(projectId: f.project.id, now: now + 2), [aHairUnder.id])
    }

    func testAfterDaysNeverArchivesATaskOutsideDone() throws {
        let f = try Fixture.make()
        try f.setPolicy(.afterDays(1))
        let stale = try f.doneTask("stale", daysInDone: 90)
        try f.tasks.move(stale.id, to: .review)
        let others = try [TaskColumn.proposed, .backlog, .ready, .running, .review].map {
            try f.task("in-\($0.rawValue)", column: $0)
        }

        XCTAssertEqual(try ArchiveSweep(f.db).run(projectId: f.project.id), [])
        XCTAssertFalse(try f.isArchived(stale.id))
        for task in others {
            XCTAssertFalse(try f.isArchived(task.id), "\(task.column.rawValue) must never archive")
        }
    }

    func testAfterDaysIsIdempotent() throws {
        let f = try Fixture.make()
        try f.setPolicy(.afterDays(2))
        let old = try f.doneTask("old", daysInDone: 30)
        let sweep = ArchiveSweep(f.db)

        XCTAssertEqual(try sweep.run(projectId: f.project.id), [old.id])
        let stampedAt = try XCTUnwrap(f.tasks.get(old.id)?.archivedAt)
        XCTAssertEqual(try sweep.run(projectId: f.project.id), [])
        XCTAssertEqual(try f.tasks.get(old.id)?.archivedAt, stampedAt)
    }

    func testAnUnarchivedTaskIsNotReArchivedByTheNextTick() throws {
        let f = try Fixture.make()
        try f.setPolicy(.afterDays(2))
        let old = try f.doneTask("old", daysInDone: 30)
        let sweep = ArchiveSweep(f.db)
        XCTAssertEqual(try sweep.run(projectId: f.project.id), [old.id])

        try f.tasks.unarchive(old.id)

        XCTAssertEqual(try sweep.run(projectId: f.project.id), [])
        XCTAssertEqual(try sweep.run(projectId: f.project.id), [])
        XCTAssertFalse(try f.isArchived(old.id))
        XCTAssertEqual(try f.tasks.get(old.id)?.column, .done)
    }

    func testReopeningAnUnarchivedTaskPutsItBackUnderThePolicy() throws {
        let f = try Fixture.make()
        try f.setPolicy(.afterDays(0))
        let task = try f.doneTask("a", daysInDone: 30)
        try ArchiveSweep(f.db).run(projectId: f.project.id)
        try f.tasks.unarchive(task.id)
        try f.tasks.move(task.id, to: .ready)

        try f.tasks.move(task.id, to: .done)

        XCTAssertNil(try f.tasks.get(task.id)?.unarchivedAt)
        XCTAssertEqual(try ArchiveSweep(f.db).run(projectId: f.project.id, now: .nowMillis + 1), [task.id])
    }

    func testASweepOnlyTouchesItsOwnProject() throws {
        let f = try Fixture.make()
        try f.setPolicy(.afterDays(1))
        let mine = try f.doneTask("mine", daysInDone: 9)
        let other = try f.projects.register(
            name: "Other", repoPath: "/tmp/other-\(UUID().uuidString)", baseBranch: "main",
            worktreeRoot: "/tmp/other-worktrees", memoryDir: nil
        )
        let theirs = try f.tasks.create(
            projectId: other.id, title: "theirs", body: nil, acceptance: nil, priority: nil,
            column: .done, origin: .human, epicId: nil
        )
        try f.db.writer.write { db in
            try db.execute(sql: "UPDATE task SET done_at = ? WHERE id = ?", arguments: [Int64.nowMillis - 9 * ArchiveSweep.millisPerDay, theirs.id])
        }

        XCTAssertEqual(try ArchiveSweep(f.db).run(projectId: f.project.id), [mine.id])
        XCTAssertFalse(try f.isArchived(theirs.id))
    }

    // MARK: - afterEpicMerge

    func testAfterEpicMergeArchivesNothingOnATick() throws {
        let f = try Fixture.make()
        try f.setPolicy(.afterEpicMerge)
        let ancient = try f.doneTask("ancient", daysInDone: 400)

        XCTAssertEqual(try ArchiveSweep(f.db).run(projectId: f.project.id), [])
        XCTAssertFalse(try f.isArchived(ancient.id))
    }

    func testAfterEpicMergeArchivesEveryTaskOfTheEpicIncludingTheIntegrationTask() throws {
        let f = try Fixture.make()
        try f.setPolicy(.afterEpicMerge)
        let merged = try f.mergeAnEpic(taskTitles: ["schema", "api", "ui"])

        XCTAssertEqual(try f.epics.get(merged.epic.id)?.state, .done)
        for id in merged.memberIds {
            XCTAssertTrue(try f.isArchived(id), "epic member \(id) should have archived on merge")
        }
        let integration = try XCTUnwrap(f.tasks.get(merged.integrationTaskId))
        XCTAssertTrue(integration.isArchived, "the integration task should archive with its epic")
        XCTAssertEqual(integration.column, .done)
        XCTAssertEqual(try f.tasks.list(projectId: f.project.id), [])
    }

    func testAfterEpicMergeArchivesNothingForAnEpicStillIntegrating() throws {
        let f = try Fixture.make()
        try f.setPolicy(.afterEpicMerge)
        let (epic, members) = try f.epic(["schema", "api"])
        try f.epics.setState(epic.id, .integrating)
        let integration = try f.board.createIntegrationTask(epicId: epic.id)

        XCTAssertEqual(try f.epics.get(epic.id)?.state, .integrating)
        for member in members {
            XCTAssertFalse(try f.isArchived(member.id))
        }
        XCTAssertFalse(try f.isArchived(integration.id))
        XCTAssertEqual(try ArchiveSweep(f.db).run(projectId: f.project.id), [])
    }

    func testAStandaloneDoneTaskIsUntouchedByAnEpicMerge() throws {
        let f = try Fixture.make()
        try f.setPolicy(.afterEpicMerge)
        let standalone = try f.doneTask("no epic of its own", daysInDone: 500)

        let merged = try f.mergeAnEpic(taskTitles: ["api"])

        XCTAssertTrue(try f.isArchived(merged.memberIds[0]))
        XCTAssertFalse(try f.isArchived(standalone.id), "a task with no epic has no merge event and stays visible")
        XCTAssertEqual(try f.tasks.list(projectId: f.project.id).map(\.id), [standalone.id])
    }

    func testMergingOneEpicLeavesAnotherEpicsTasksAlone() throws {
        let f = try Fixture.make()
        try f.setPolicy(.afterEpicMerge)
        let (bystander, bystanderTasks) = try f.epic(["untouched"])

        let merged = try f.mergeAnEpic(taskTitles: ["api"])

        XCTAssertTrue(try f.isArchived(merged.memberIds[0]))
        XCTAssertFalse(try f.isArchived(bystanderTasks[0].id))
        XCTAssertEqual(try f.epics.get(bystander.id)?.state, .planning)
    }

    func testAnEpicMergeSkipsANonDoneTaskRatherThanFailing() throws {
        let f = try Fixture.make()
        try f.setPolicy(.afterEpicMerge)
        let (epic, members) = try f.epic(["done one", "stranded"])
        try f.tasks.move(members[1].id, to: .running)

        let merged = try f.completeIntegration(of: epic)

        XCTAssertEqual(try f.epics.get(epic.id)?.state, .done)
        XCTAssertTrue(try f.isArchived(members[0].id))
        XCTAssertFalse(try f.isArchived(members[1].id))
        XCTAssertEqual(try f.tasks.get(members[1].id)?.column, .running)
        XCTAssertTrue(try f.isArchived(merged.integrationTaskId))
    }

    func testAnEpicMergeDoesNotReArchiveAManuallyUnarchivedTask() throws {
        let f = try Fixture.make()
        try f.setPolicy(.afterEpicMerge)
        let (epic, members) = try f.epic(["api"])
        try f.tasks.archive(members[0].id)
        try f.tasks.unarchive(members[0].id)

        _ = try f.completeIntegration(of: epic)

        XCTAssertFalse(try f.isArchived(members[0].id))
    }
}

// MARK: - epic fixtures

private struct MergedEpic {
    let epic: Epic
    let memberIds: [String]
    let integrationTaskId: String
}

private extension Fixture {
    /// An epic whose tasks are all in `done` — §5.2 step 1.
    func epic(_ titles: [String]) throws -> (Epic, [BoardTask]) {
        let (epic, created) = try board.createEpic(
            projectId: project.id, title: "Ship search", goal: "make it fast",
            tasks: titles.map { NewEpicTask(title: $0) }
        )
        for task in created {
            try tasks.move(task.id, to: .done)
        }
        return (epic, created)
    }

    /// Drives §5.2 to its end: the epic goes `integrating`, the integrator reports, and
    /// `Board.complete` moves the epic to `done` in one transaction.
    func completeIntegration(of epic: Epic) throws -> MergedEpic {
        try epics.setState(epic.id, .integrating)
        let integration = try board.createIntegrationTask(epicId: epic.id)
        let session = self.session(taskId: integration.id)
        try sessions.insert(session)
        try board.complete(taskId: integration.id, sessionId: session.sessionId, summary: "merged everything")
        let members = try tasks.list(projectId: project.id, epicId: epic.id, includeArchived: true)
            .filter { $0.origin != .integration }
        return MergedEpic(epic: epic, memberIds: members.map(\.id), integrationTaskId: integration.id)
    }

    func mergeAnEpic(taskTitles: [String]) throws -> MergedEpic {
        let (epic, _) = try self.epic(taskTitles)
        return try completeIntegration(of: epic)
    }
}
