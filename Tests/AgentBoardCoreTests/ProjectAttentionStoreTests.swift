import GRDB
import XCTest
@testable import AgentBoardCore

final class ProjectAttentionStoreTests: XCTestCase {
    private let grace = ProjectAttentionStore.shutdownGraceSeconds
    private let now: Int64 = 1_700_000_000_000

    private func attention(_ f: Fixture, now: Int64? = nil) throws -> ProjectAttention {
        let all = try ProjectAttentionStore(f.db).all(now: now ?? self.now, graceSeconds: grace)
        return try XCTUnwrap(all.first { $0.id == f.project.id })
    }

    /// A worker that blocks needs a session row: the `blocked` report it writes has a foreign key
    /// onto one.
    @discardableResult
    private func blockAWorker(_ f: Fixture, reason: String = "need a decision") throws -> BoardTask {
        let task = try f.task("Wire the thing", column: .running)
        try f.sessions.insert(f.session("w-block", state: .running, taskId: task.id))
        _ = try f.board.block(taskId: task.id, sessionId: "w-block", reason: reason)
        return task
    }

    private func overdueShutdown(_ f: Fixture, orderedAt: Int64) throws -> ShutdownOrder {
        let order = try ShutdownOrderStore(f.db).request(projectId: f.project.id, requestedBy: "human")
        try ShutdownDeliveryStore(f.db).enroll(
            orderId: order.id, sessionId: "w-shutdown", taskId: nil, at: orderedAt
        )
        return order
    }

    // MARK: - nothing to say

    func testAProjectWithNothingWaitingDoesNotNeedAttention() throws {
        let f = try Fixture.make()
        let signal = try attention(f)
        XCTAssertFalse(signal.needsAttention)
        XCTAssertEqual(signal.count, 0)
        XCTAssertEqual(signal.causes, [])
        XCTAssertNil(signal.summary)
        XCTAssertNil(signal.badgeCount)
    }

    /// Busy is not the same as needing a human.
    func testAHealthyRunningWorkerIsNotAttention() throws {
        let f = try Fixture.make()
        let task = try f.task("Build it", column: .running)
        try f.sessions.insert(f.session("w1", state: .running, taskId: task.id))
        try f.progress.append(taskId: task.id, sessionId: "w1", kind: .tool, text: "Bash")

        XCTAssertFalse(try attention(f).needsAttention)
    }

    func testEveryProjectIsListedIncludingQuietOnes() throws {
        let f = try Fixture.make()
        let other = try ProjectStore(f.db).register(
            name: "Other", repoPath: "/tmp/other-\(UUID().uuidString)", baseBranch: "main",
            worktreeRoot: "/tmp/w", memoryDir: nil
        )
        let all = try ProjectAttentionStore(f.db).all(now: now)
        XCTAssertEqual(all.map(\.id).sorted(), [f.project.id, other.id].sorted())
        XCTAssertTrue(all.allSatisfy { !$0.needsAttention })
    }

    // MARK: - pending approval

    func testAPendingApprovalRaisesTheSignal() throws {
        let f = try Fixture.make()
        try ApprovalStore(f.db).create(
            projectId: f.project.id, kind: .spawn, taskId: nil, epicId: nil,
            requestedBy: "orchestrator", reason: "spawn a worker"
        )

        let signal = try attention(f)
        XCTAssertTrue(signal.needsAttention)
        XCTAssertEqual(signal.reasons, [.pendingApproval])
        XCTAssertEqual(signal.count, 1)
        XCTAssertEqual(signal.summary, "1 approval waiting.")
    }

    func testResolvingTheApprovalLowersTheSignal() throws {
        let f = try Fixture.make()
        let approval = try ApprovalStore(f.db).create(
            projectId: f.project.id, kind: .spawn, taskId: nil, epicId: nil,
            requestedBy: "orchestrator", reason: nil
        )
        XCTAssertTrue(try attention(f).needsAttention)

        try ApprovalStore(f.db).resolve(approval.id, .denied)

        XCTAssertFalse(try attention(f).needsAttention)
    }

    func testEveryPendingApprovalCounts() throws {
        let f = try Fixture.make()
        for _ in 0..<3 {
            try ApprovalStore(f.db).create(
                projectId: f.project.id, kind: .push, taskId: nil, epicId: nil,
                requestedBy: "orchestrator", reason: nil
            )
        }
        XCTAssertEqual(try attention(f).cause(.pendingApproval)?.count, 3)
        XCTAssertEqual(try attention(f).summary, "3 approvals waiting.")
    }

    // MARK: - blocked worker

    func testAWorkerThatReportedBlockedRaisesTheSignal() throws {
        let f = try Fixture.make()
        try blockAWorker(f)

        let signal = try attention(f)
        XCTAssertTrue(signal.has(.blockedWorker))
        XCTAssertEqual(signal.cause(.blockedWorker)?.count, 1)
        XCTAssertEqual(signal.cause(.blockedWorker)?.detail, "Wire the thing")
    }

    func testUnblockingTheTaskLowersTheBlockedSignal() throws {
        let f = try Fixture.make()
        let task = try blockAWorker(f)
        XCTAssertTrue(try attention(f).has(.blockedWorker))

        try f.board.unblock(taskId: task.id, sessionId: "w-block")

        XCTAssertFalse(try attention(f).has(.blockedWorker))
    }

    /// The task row is the durable evidence, not the session: a blocked worker whose session was
    /// killed still needs the same answer from the same human.
    func testABlockedTaskWhoseSessionEndedStillRaisesTheSignal() throws {
        let f = try Fixture.make()
        try blockAWorker(f)
        try f.sessions.setState("w-block", .stopped, endedAt: now)

        XCTAssertTrue(try attention(f).has(.blockedWorker))
    }

    func testAnArchivedBlockedTaskIsNotAttention() throws {
        let f = try Fixture.make()
        let task = try blockAWorker(f)
        try f.tasks.move(task.id, to: .done)
        try f.tasks.archive(task.id)

        XCTAssertFalse(try attention(f).has(.blockedWorker))
    }

    func testTheDetailNamesTheLongestBlockedTask() throws {
        let f = try Fixture.make()
        let first = try blockAWorker(f)
        let second = try f.task("Later problem", column: .running)
        try f.sessions.insert(f.session("w-block-2", state: .running, taskId: second.id))
        _ = try f.board.block(taskId: second.id, sessionId: "w-block-2", reason: "also stuck")
        try f.db.writer.write { db in
            try db.execute(sql: "UPDATE task SET updated_at = ? WHERE id = ?", arguments: [now, first.id])
            try db.execute(sql: "UPDATE task SET updated_at = ? WHERE id = ?", arguments: [now + 5_000, second.id])
        }

        let cause = try XCTUnwrap(attention(f).cause(.blockedWorker))
        XCTAssertEqual(cause.count, 2)
        XCTAssertEqual(cause.detail, "Wire the thing")
    }

    // MARK: - stranded reports

    func testUnconsumedReportsWithNoOrchestratorRaiseTheSignal() throws {
        let f = try Fixture.make()
        try f.reports.insert(
            projectId: f.project.id, taskId: nil, sessionId: nil, kind: .proposal, body: "an idea"
        )

        let signal = try attention(f)
        XCTAssertEqual(signal.reasons, [.strandedReports])
        XCTAssertEqual(signal.summary, "1 report waiting with no orchestrator running.")
    }

    func testARunningOrchestratorMeansTheReportsAreNotStranded() throws {
        let f = try Fixture.make()
        try f.reports.insert(
            projectId: f.project.id, taskId: nil, sessionId: nil, kind: .proposal, body: "an idea"
        )
        XCTAssertTrue(try attention(f).has(.strandedReports))

        try f.sessions.insert(f.session("orch", role: .orchestrator, state: .running))

        XCTAssertFalse(try attention(f).needsAttention)
    }

    func testAnOrchestratorThatEndedLeavesTheReportsStranded() throws {
        let f = try Fixture.make()
        try f.sessions.insert(f.session("orch", role: .orchestrator, state: .running))
        try f.reports.insert(
            projectId: f.project.id, taskId: nil, sessionId: nil, kind: .proposal, body: "an idea"
        )
        XCTAssertFalse(try attention(f).needsAttention)

        try f.sessions.setState("orch", .stopped, endedAt: now)

        XCTAssertTrue(try attention(f).has(.strandedReports))
    }

    func testConsumingTheReportsLowersTheSignal() throws {
        let f = try Fixture.make()
        try f.reports.insert(
            projectId: f.project.id, taskId: nil, sessionId: nil, kind: .proposal, body: "one"
        )
        try f.reports.insert(
            projectId: f.project.id, taskId: nil, sessionId: nil, kind: .proposal, body: "two"
        )
        XCTAssertEqual(try attention(f).cause(.strandedReports)?.count, 2)

        try f.reports.consumeAll(projectId: f.project.id)

        XCTAssertFalse(try attention(f).needsAttention)
    }

    /// A worker session is not an orchestrator, so its own reports still strand.
    func testAWorkerSessionDoesNotUnstrandReports() throws {
        let f = try Fixture.make()
        try f.sessions.insert(f.session("w1", role: .worker, state: .running))
        try f.reports.insert(
            projectId: f.project.id, taskId: nil, sessionId: "w1", kind: .complete, body: "done"
        )

        XCTAssertTrue(try attention(f).has(.strandedReports))
    }

    // MARK: - overdue shutdown

    func testAnOverdueUnacknowledgedDeliveryRaisesTheSignal() throws {
        let f = try Fixture.make()
        try overdueShutdown(f, orderedAt: now - Int64(grace) * 1000)

        let signal = try attention(f)
        XCTAssertEqual(signal.reasons, [.overdueShutdown])
        XCTAssertEqual(signal.summary, "1 agent has not acknowledged shutdown.")
    }

    func testADeliveryInsideTheGracePeriodIsNotAttention() throws {
        let f = try Fixture.make()
        try overdueShutdown(f, orderedAt: now - Int64(grace) * 1000 + 1)

        XCTAssertFalse(try attention(f).needsAttention)
    }

    func testAcknowledgingTheShutdownLowersTheSignal() throws {
        let f = try Fixture.make()
        let order = try overdueShutdown(f, orderedAt: now - 600_000)
        XCTAssertTrue(try attention(f).has(.overdueShutdown))

        try f.db.writer.write { db in
            try ShutdownDeliveryStore.acknowledge(
                db, orderId: order.id, sessionId: "w-shutdown", taskId: nil, note: "stopping", at: now
            )
        }

        XCTAssertFalse(try attention(f).has(.overdueShutdown))
    }

    func testCancellingTheOrderLowersTheSignal() throws {
        let f = try Fixture.make()
        try overdueShutdown(f, orderedAt: now - 600_000)
        XCTAssertTrue(try attention(f).has(.overdueShutdown))

        try ShutdownOrderStore(f.db).cancel(projectId: f.project.id, by: "human")

        XCTAssertFalse(try attention(f).has(.overdueShutdown))
    }

    // MARK: - a failed task

    /// `Board.fail` queues a `failed` report for the orchestrator, which is the agent whose job it
    /// is to retry or re-scope. With one running, the human is not needed.
    func testAFailedTaskWithARunningOrchestratorIsNotAttention() throws {
        let f = try Fixture.make()
        try f.sessions.insert(f.session("orch", role: .orchestrator, state: .running))
        let task = try f.task("Break it", column: .running)
        try f.sessions.insert(f.session("w1", state: .running, taskId: task.id))
        _ = try f.board.fail(taskId: task.id, sessionId: "w1", reason: "tests never passed")

        let signal = try attention(f)
        XCTAssertFalse(signal.needsAttention, "a failure is the orchestrator's to handle")
    }

    /// …and when no orchestrator will ever read it, the same failure surfaces as a stranded report
    /// rather than as a second, separate reason.
    func testAFailedTaskWithNoOrchestratorSurfacesAsAStrandedReport() throws {
        let f = try Fixture.make()
        let task = try f.task("Break it", column: .running)
        try f.sessions.insert(f.session("w1", state: .running, taskId: task.id))
        _ = try f.board.fail(taskId: task.id, sessionId: "w1", reason: "tests never passed")

        XCTAssertEqual(try attention(f).reasons, [.strandedReports])
    }

    // MARK: - combining

    func testCausesComeBackInSeverityOrderAndTheCountSumsThem() throws {
        let f = try Fixture.make()
        try ApprovalStore(f.db).create(
            projectId: f.project.id, kind: .spawn, taskId: nil, epicId: nil,
            requestedBy: "orchestrator", reason: nil
        )
        try blockAWorker(f)
        try overdueShutdown(f, orderedAt: now - 600_000)

        let signal = try attention(f)
        // `block` queues a report of its own, and no orchestrator is running to take it.
        XCTAssertEqual(signal.reasons, [.pendingApproval, .blockedWorker, .strandedReports, .overdueShutdown])
        XCTAssertEqual(signal.count, 4)
        XCTAssertEqual(signal.badgeCount, 4)
        XCTAssertEqual(
            signal.summary,
            "1 approval waiting, 1 worker blocked: Wire the thing, "
                + "1 report waiting with no orchestrator running, "
                + "1 agent has not acknowledged shutdown."
        )
    }

    func testOneProjectsAttentionDoesNotLeakIntoAnother() throws {
        let f = try Fixture.make()
        let other = try ProjectStore(f.db).register(
            name: "Other", repoPath: "/tmp/other-\(UUID().uuidString)", baseBranch: "main",
            worktreeRoot: "/tmp/w", memoryDir: nil
        )
        try ApprovalStore(f.db).create(
            projectId: other.id, kind: .spawn, taskId: nil, epicId: nil, requestedBy: "orchestrator", reason: nil
        )

        XCTAssertFalse(try attention(f).needsAttention)
        let store = ProjectAttentionStore(f.db)
        XCTAssertTrue(try XCTUnwrap(store.attention(projectId: other.id, now: now)).needsAttention)
    }

    // MARK: - derived from the database, not from events

    /// The signal is a query, so a relaunch that never saw the approval get created still reports it.
    func testTheSignalSurvivesARelaunch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("attention-relaunch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("board.sqlite")

        let projectId: String
        do {
            let first = try AppDatabase.open(at: url)
            let project = try ProjectStore(first).register(
                name: "Demo", repoPath: "/tmp/relaunch-\(UUID().uuidString)", baseBranch: "main",
                worktreeRoot: "/tmp/w", memoryDir: nil
            )
            projectId = project.id
            try ApprovalStore(first).create(
                projectId: project.id, kind: .integration, taskId: nil, epicId: nil,
                requestedBy: "orchestrator", reason: "integrate the epic"
            )
            let task = try TaskStore(first).create(
                projectId: project.id, title: "Wire the thing", body: nil, acceptance: nil,
                priority: nil, column: .running, origin: .human, epicId: nil
            )
            try SessionStore(first).insert(
                AgentSession(sessionId: "w-block", projectId: project.id, taskId: task.id,
                             role: .worker, cwd: "/tmp", state: .running)
            )
            _ = try Board(first).block(taskId: task.id, sessionId: "w-block", reason: "need a decision")
        }

        let reopened = try AppDatabase.open(at: url)
        let signal = try XCTUnwrap(ProjectAttentionStore(reopened).attention(projectId: projectId, now: now))
        XCTAssertEqual(signal.reasons, [.pendingApproval, .blockedWorker, .strandedReports])
        XCTAssertEqual(signal.cause(.blockedWorker)?.detail, "Wire the thing")
    }

    // MARK: - observation

    func testTheObservationEmitsWhenAnApprovalArrivesAndWhenItResolves() throws {
        let f = try Fixture.make()
        var approvalId = ""

        let values = try observe(f.db, changes: 2) {
            approvalId = try ApprovalStore(f.db).create(
                projectId: f.project.id, kind: .spawn, taskId: nil, epicId: nil,
                requestedBy: "orchestrator", reason: nil
            ).id
            try ApprovalStore(f.db).resolve(approvalId, .approved)
        }

        XCTAssertEqual(values.map { $0.first?.needsAttention }, [false, true, false])
    }

    func testTheObservationEmitsWhenAWorkerBlocks() throws {
        let f = try Fixture.make()
        let task = try f.task("Wire the thing", column: .running)
        try f.sessions.insert(f.session("w-block", state: .running, taskId: task.id))

        let values = try observe(f.db, changes: 1) {
            _ = try f.board.block(taskId: task.id, sessionId: "w-block", reason: "need a decision")
        }

        XCTAssertEqual(values.first?.first?.reasons, [])
        XCTAssertEqual(values.last?.first?.reasons, [.blockedWorker, .strandedReports])
    }

    /// One SELECT for one project, one for a dozen. GRDB's `read` wraps it in BEGIN/COMMIT, which
    /// the filter drops.
    func testTheQueryCountDoesNotGrowWithProjectCount() throws {
        func selects(projects: Int) throws -> [String] {
            let db = try AppDatabase.inMemory()
            for i in 0..<projects {
                let project = try ProjectStore(db).register(
                    name: "P\(i)", repoPath: "/tmp/p\(i)-\(UUID().uuidString)", baseBranch: "main",
                    worktreeRoot: "/tmp/w", memoryDir: nil
                )
                try ApprovalStore(db).create(
                    projectId: project.id, kind: .spawn, taskId: nil, epicId: nil,
                    requestedBy: "orchestrator", reason: nil
                )
            }
            let log = Log()
            try db.reader.read { db in
                db.trace(options: .statement) { log.sql.append("\($0)") }
                _ = try ProjectAttentionStore.all(db, now: now, graceSeconds: grace)
            }
            return log.sql.filter { $0.uppercased().hasPrefix("SELECT") }
        }

        XCTAssertEqual(try selects(projects: 1).count, 1)
        XCTAssertEqual(try selects(projects: 12).count, 1)
    }

    private final class Log: @unchecked Sendable {
        var sql: [String] = []
    }

    /// Starts the observation, runs `body`, and returns the initial value plus `changes` more.
    private func observe(
        _ db: AppDatabase, changes: Int, _ body: () throws -> Void
    ) throws -> [[ProjectAttention]] {
        let emitted = expectation(description: "\(changes) change(s) after the initial value")
        let box = Box()
        let frozen = now
        let cancellable = ProjectAttentionStore(db)
            .observeAll(graceSeconds: grace, clock: { frozen })
            .start(
                in: db.reader,
                scheduling: .immediate,
                onError: { XCTFail("observation failed: \($0)") },
                onChange: { value in
                    box.values.append(value)
                    if box.values.count == changes + 1 { emitted.fulfill() }
                }
            )
        defer { cancellable.cancel() }
        try body()
        wait(for: [emitted], timeout: 5)
        return box.values
    }

    private final class Box: @unchecked Sendable {
        var values: [[ProjectAttention]] = []
    }
}
