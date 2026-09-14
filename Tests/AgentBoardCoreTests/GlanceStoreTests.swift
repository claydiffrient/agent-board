import GRDB
import XCTest
@testable import AgentBoardCore

final class GlanceStoreTests: XCTestCase {
    private func addProject(_ db: AppDatabase, named name: String) throws -> Project {
        try ProjectStore(db).register(
            name: name,
            repoPath: "/tmp/glance-\(UUID().uuidString)",
            baseBranch: "main",
            worktreeRoot: "/tmp/demo-worktrees",
            memoryDir: nil
        )
    }

    @discardableResult
    private func addTask(_ db: AppDatabase, _ project: Project, _ column: TaskColumn) throws -> BoardTask {
        try TaskStore(db).create(
            projectId: project.id, title: "t-\(column.rawValue)", body: nil, acceptance: nil,
            priority: nil, column: column, origin: .human, epicId: nil
        )
    }

    func testCountsEachColumnPerProject() throws {
        let f = try Fixture.make()
        try addTask(f.db, f.project, .running)
        try addTask(f.db, f.project, .running)
        try addTask(f.db, f.project, .review)
        try addTask(f.db, f.project, .ready)
        try addTask(f.db, f.project, .backlog)
        try addTask(f.db, f.project, .done)

        let summary = try GlanceStore(f.db).summary()
        let glance = try XCTUnwrap(summary.projects.first { $0.id == f.project.id })
        XCTAssertEqual(glance.name, "Demo")
        XCTAssertEqual(glance.running, 2)
        XCTAssertEqual(glance.review, 1)
        XCTAssertEqual(glance.ready, 1)
    }

    func testProjectWithNoTasksAppearsWithZeroes() throws {
        let f = try Fixture.make()
        let idle = try addProject(f.db, named: "Zed")
        try addTask(f.db, f.project, .running)

        let summary = try GlanceStore(f.db).summary()
        XCTAssertEqual(summary.projects.count, 2)
        let glance = try XCTUnwrap(summary.projects.first { $0.id == idle.id })
        XCTAssertEqual([glance.running, glance.review, glance.ready], [0, 0, 0])
    }

    func testProjectsOrderedByNameLikeProjectStore() throws {
        let f = try Fixture.make()
        try addProject(f.db, named: "apple")
        try addProject(f.db, named: "Zed")

        let names = try GlanceStore(f.db).summary().projects.map(\.name)
        XCTAssertEqual(names, ["apple", "Demo", "Zed"])
        XCTAssertEqual(names, try ProjectStore(f.db).list().map(\.name))
    }

    func testTotalsSumEveryProject() throws {
        let f = try Fixture.make()
        let other = try addProject(f.db, named: "Other")
        try addTask(f.db, f.project, .review)
        try addTask(f.db, other, .review)
        try addTask(f.db, other, .review)
        try addTask(f.db, other, .ready)

        let summary = try GlanceStore(f.db).summary()
        XCTAssertEqual(summary.tasksInReview, 3)
    }

    func testArchivingADoneTaskMovesNoCount() throws {
        let f = try Fixture.make()
        try addTask(f.db, f.project, .running)
        try addTask(f.db, f.project, .review)
        try addTask(f.db, f.project, .ready)
        let done = try addTask(f.db, f.project, .done)

        let before = try GlanceStore(f.db).summary()
        try TaskStore(f.db).archive(done.id)
        let after = try GlanceStore(f.db).summary()

        XCTAssertEqual(before, after)
        XCTAssertEqual(after.projects.first?.running, 1)
        XCTAssertEqual(after.projects.first?.review, 1)
        XCTAssertEqual(after.projects.first?.ready, 1)
    }

    func testArchivedTasksInCountedColumnsAreExcluded() throws {
        let f = try Fixture.make()
        let task = try addTask(f.db, f.project, .done)
        try TaskStore(f.db).archive(task.id)
        try f.db.writer.write { db in
            try db.execute(
                sql: "UPDATE task SET column_name = 'review' WHERE id = ?", arguments: [task.id]
            )
        }

        let summary = try GlanceStore(f.db).summary()
        XCTAssertEqual(summary.projects.first?.review, 0)
        XCTAssertEqual(summary.tasksInReview, 0)
    }

    func testWorkingSessionsCountsActiveWorkersAcrossProjects() throws {
        let f = try Fixture.make()
        let other = try addProject(f.db, named: "Other")
        let sessions = SessionStore(f.db)
        try sessions.insert(f.session("w-running", role: .worker, state: .running))
        try sessions.insert(f.session("w-idle", role: .worker, state: .idle))
        try sessions.insert(
            AgentSession(sessionId: "w-other", projectId: other.id, role: .worker, cwd: "/tmp", state: .blocked)
        )

        XCTAssertEqual(try GlanceStore(f.db).summary().workingSessions, 3)
    }

    func testEndedWorkerSessionsAreNotWorking() throws {
        let f = try Fixture.make()
        let sessions = SessionStore(f.db)
        try sessions.insert(f.session("w-stopped", role: .worker, state: .stopped))
        try sessions.insert(f.session("w-failed", role: .worker, state: .failed))
        try sessions.insert(f.session("w-completed", role: .worker, state: .completed))

        XCTAssertEqual(try GlanceStore(f.db).summary().workingSessions, 0)
    }

    /// A session in `setup` holds a concurrency slot and becomes a running agent, so the page must
    /// not read "nothing is happening" while its worktree is being prepared.
    func testSetupCountsAsWorking() throws {
        let f = try Fixture.make()
        try SessionStore(f.db).insert(f.session("w-setup", role: .worker, state: .setup))

        XCTAssertEqual(try GlanceStore(f.db).summary().workingSessions, 1)
    }

    /// The human's own orchestrator is not an agent working for them.
    func testOrchestratorDoesNotCountAsWorking() throws {
        let f = try Fixture.make()
        try SessionStore(f.db).insert(f.session("orch", role: .orchestrator, state: .running))

        XCTAssertEqual(try GlanceStore(f.db).summary().workingSessions, 0)
    }

    func testObservationEmitsWhenATaskChangesColumn() throws {
        let f = try Fixture.make()
        let task = try addTask(f.db, f.project, .ready)

        let values = try observe(f.db, changes: 1) {
            try TaskStore(f.db).move(task.id, to: .running)
        }

        XCTAssertEqual(values.first?.projects.first?.ready, 1)
        XCTAssertEqual(values.first?.projects.first?.running, 0)
        XCTAssertEqual(values.last?.projects.first?.ready, 0)
        XCTAssertEqual(values.last?.projects.first?.running, 1)
    }

    func testObservationEmitsWhenASessionStartsAndEnds() throws {
        let f = try Fixture.make()

        let values = try observe(f.db, changes: 2) {
            try SessionStore(f.db).insert(f.session("w1", role: .worker, state: .running))
            try SessionStore(f.db).setState("w1", .completed, endedAt: .nowMillis)
        }

        XCTAssertEqual(values.map(\.workingSessions), [0, 1, 0])
    }

    /// Two SELECTs for one project, two for a dozen: the per-project counts are one grouped pass,
    /// not a query per project. GRDB's `read` adds its own BEGIN/COMMIT, which the filter drops.
    func testQueryCountDoesNotGrowWithProjectCount() throws {
        func selects(projects: Int) throws -> [String] {
            let db = try AppDatabase.inMemory()
            for i in 0..<projects {
                let project = try addProject(db, named: "P\(i)")
                try addTask(db, project, .running)
                try addTask(db, project, .review)
            }
            let log = Log()
            try db.reader.read { db in
                db.trace(options: .statement) { log.sql.append("\($0)") }
                _ = try GlanceStore.summary(db)
            }
            return log.sql.filter { $0.uppercased().hasPrefix("SELECT") }
        }

        XCTAssertEqual(try selects(projects: 1).count, 2)
        XCTAssertEqual(try selects(projects: 12).count, 2)
    }

    private final class Log: @unchecked Sendable {
        var sql: [String] = []
    }

    /// Starts the observation, runs `body`, and returns the initial value plus `changes` more.
    private func observe(
        _ db: AppDatabase, changes: Int, _ body: () throws -> Void
    ) throws -> [GlanceSummary] {
        let emitted = expectation(description: "\(changes) change(s) after the initial value")
        let box = Box()
        let cancellable = GlanceStore(db).observe().start(
            in: db.reader,
            scheduling: .immediate,
            onError: { XCTFail("observation failed: \($0)") },
            onChange: { summary in
                box.values.append(summary)
                if box.values.count == changes + 1 { emitted.fulfill() }
            }
        )
        defer { cancellable.cancel() }
        try body()
        wait(for: [emitted], timeout: 5)
        return box.values
    }

    private final class Box: @unchecked Sendable {
        var values: [GlanceSummary] = []
    }
}
