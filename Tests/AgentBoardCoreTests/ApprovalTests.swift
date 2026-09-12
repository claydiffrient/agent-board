import Foundation
import GRDB
import XCTest
@testable import AgentBoardCore

extension Fixture {
    var approvals: ApprovalStore { ApprovalStore(db) }

    func setAutonomy(_ enabled: Bool) throws {
        var settings = project.settings
        settings.autonomyEnabled = enabled
        try projects.updateSettings(project.id, settings)
    }
}

final class ApprovalMigrationTests: XCTestCase {
    func testApprovalMigrationCreatesTableAndIndex() throws {
        let db = try AppDatabase.inMemory()
        try db.reader.read { db in
            XCTAssertTrue(try db.tableExists("approval"))
            let columns = try db.columns(in: "approval")
            XCTAssertEqual(
                columns.map(\.name),
                ["id", "project_id", "kind", "task_id", "epic_id", "requested_by", "reason", "created_at", "resolved_at", "resolution"]
            )
            XCTAssertTrue(columns.contains { $0.name == "requested_by" && $0.isNotNull })
            XCTAssertEqual(columns.first { $0.name == "resolved_at" }?.isNotNull, false)
            let indexes = try db.indexes(on: "approval").map(\.name)
            XCTAssertTrue(indexes.contains("approval_pending"))
        }
        let applied = try db.writer.read { try AppDatabase.migrator.appliedIdentifiers($0) }
        XCTAssertEqual(applied, ["v1", "task_model", "approval", "note_section_written_by", "task_archived_at", "task_done_at"])
    }

    func testApprovalRequiresExistingProjectAndTask() throws {
        let f = try Fixture.make()
        XCTAssertThrowsError(try f.approvals.create(projectId: "missing", kind: .spawn, taskId: nil, epicId: nil, requestedBy: "human", reason: nil))
        XCTAssertThrowsError(try f.approvals.create(projectId: f.project.id, kind: .spawn, taskId: "missing", epicId: nil, requestedBy: "human", reason: nil))
        XCTAssertEqual(try f.approvals.pending(projectId: f.project.id).count, 0)
    }
}

final class ApprovalStoreTests: XCTestCase {
    func testCreateGetAndPendingOldestFirst() throws {
        let f = try Fixture.make()
        let other = try f.projects.register(name: "Other", repoPath: "/other", baseBranch: "main", worktreeRoot: "/w", memoryDir: nil)
        let t1 = try f.task("one", column: .ready)
        let t2 = try f.task("two", column: .ready)

        let a = try f.approvals.create(projectId: f.project.id, kind: .spawn, taskId: t1.id, epicId: nil, requestedBy: "orch-1", reason: nil)
        let b = try f.approvals.create(projectId: f.project.id, kind: .spawn, taskId: t2.id, epicId: nil, requestedBy: "orch-1", reason: "second")
        try f.approvals.create(projectId: other.id, kind: .integration, taskId: nil, epicId: nil, requestedBy: "human", reason: nil)

        XCTAssertEqual(try f.approvals.get(a.id), a)
        XCTAssertTrue(a.isPending)
        XCTAssertNil(a.resolution)
        XCTAssertEqual(a.kind, .spawn)
        XCTAssertEqual(a.requestedBy, "orch-1")
        XCTAssertEqual(b.reason, "second")
        XCTAssertNil(try f.approvals.get("missing"))

        try f.db.writer.write { db in
            try db.execute(sql: "UPDATE approval SET created_at = created_at - 10 WHERE id = ?", arguments: [b.id])
        }
        XCTAssertEqual(try f.approvals.pending(projectId: f.project.id).map(\.id), [b.id, a.id])
    }

    func testPendingSpawnFindsOnlyUnresolvedSpawnForTask() throws {
        let f = try Fixture.make()
        let t = try f.task("t", column: .ready)
        let other = try f.task("other", column: .ready)
        XCTAssertNil(try f.approvals.pendingSpawn(taskId: t.id))

        try f.approvals.create(projectId: f.project.id, kind: .integration, taskId: t.id, epicId: nil, requestedBy: "human", reason: nil)
        XCTAssertNil(try f.approvals.pendingSpawn(taskId: t.id))

        try f.approvals.create(projectId: f.project.id, kind: .spawn, taskId: other.id, epicId: nil, requestedBy: "o", reason: nil)
        let spawn = try f.approvals.create(projectId: f.project.id, kind: .spawn, taskId: t.id, epicId: nil, requestedBy: "o", reason: nil)
        XCTAssertEqual(try f.approvals.pendingSpawn(taskId: t.id), spawn)

        try f.approvals.resolve(spawn.id, .denied)
        XCTAssertNil(try f.approvals.pendingSpawn(taskId: t.id))
    }

    func testResolveMarksResolvedAndRejectsSecondResolution() throws {
        let f = try Fixture.make()
        let t = try f.task("t", column: .ready)
        let a = try f.approvals.create(projectId: f.project.id, kind: .spawn, taskId: t.id, epicId: nil, requestedBy: "o", reason: nil)

        let resolved = try f.approvals.resolve(a.id, .approved)
        XCTAssertEqual(resolved.id, a.id)
        XCTAssertEqual(resolved.resolution, .approved)
        XCTAssertNotNil(resolved.resolvedAt)
        XCTAssertFalse(resolved.isPending)
        XCTAssertEqual(try f.approvals.get(a.id), resolved)
        XCTAssertEqual(try f.approvals.pending(projectId: f.project.id), [])

        XCTAssertThrowsError(try f.approvals.resolve(a.id, .denied)) { error in
            XCTAssertEqual(error as? BoardError, .approvalAlreadyResolved(a.id))
        }
        XCTAssertEqual(try f.approvals.get(a.id)?.resolution, .approved)

        XCTAssertThrowsError(try f.approvals.resolve("missing", .approved)) { error in
            XCTAssertEqual(error as? BoardError, .approvalNotFound("missing"))
        }
    }

    func testObservePendingEmptiesAfterResolve() throws {
        let f = try Fixture.make()
        let t = try f.task("t", column: .ready)
        let a = try f.approvals.create(projectId: f.project.id, kind: .spawn, taskId: t.id, epicId: nil, requestedBy: "o", reason: nil)
        let emptied = expectation(description: "emptied")
        let cancellable = f.approvals.observePending(projectId: f.project.id).start(
            in: f.db.writer,
            onError: { XCTFail("\($0)") },
            onChange: { pending in
                if pending.isEmpty { emptied.fulfill() }
            }
        )
        try f.approvals.resolve(a.id, .approved)
        wait(for: [emptied], timeout: 2)
        cancellable.cancel()
    }
}

final class SpawnGateTests: XCTestCase {
    func testNotReadyTaskIsRefusedWithoutThrowing() throws {
        let f = try Fixture.make()
        for column in TaskColumn.allCases where column != .ready {
            let t = try f.task("in \(column.rawValue)", column: column)
            guard case .refused(let reason) = try f.board.requestSpawn(taskId: t.id, requestedBy: "orch") else {
                return XCTFail("expected refusal for \(column)")
            }
            XCTAssertTrue(reason.contains(column.rawValue), reason)
        }
        guard case .refused = try f.board.requestSpawn(taskId: "missing", requestedBy: "orch") else {
            return XCTFail("expected refusal for missing task")
        }
        XCTAssertEqual(try f.approvals.pending(projectId: f.project.id), [])
    }

    func testCapBreachIsRefusedBeforeAnyApprovalIsCreated() throws {
        let f = try Fixture.make()
        var settings = f.project.settings
        settings.caps.maxConcurrentWorkers = 1
        try f.projects.updateSettings(f.project.id, settings)
        try f.sessions.insert(f.session("busy", state: .running))
        let t = try f.task("t", column: .ready)

        guard case .refused(let reason) = try f.board.requestSpawn(taskId: t.id, requestedBy: "orch") else {
            return XCTFail("expected cap refusal")
        }
        XCTAssertTrue(reason.contains("1 of 1"), reason)
        XCTAssertEqual(try f.approvals.pending(projectId: f.project.id), [])
    }

    func testAutonomyOffCreatesOnePendingApprovalPerTask() throws {
        let f = try Fixture.make()
        let t = try f.task("t", column: .ready)
        let other = try f.task("other", column: .ready)

        guard case .approvalPending(let first) = try f.board.requestSpawn(taskId: t.id, requestedBy: "orch-session") else {
            return XCTFail("expected pending approval")
        }
        XCTAssertEqual(first.kind, .spawn)
        XCTAssertEqual(first.taskId, t.id)
        XCTAssertEqual(first.projectId, f.project.id)
        XCTAssertEqual(first.requestedBy, "orch-session")
        XCTAssertNil(first.reason)
        XCTAssertTrue(first.isPending)

        guard case .approvalPending(let second) = try f.board.requestSpawn(taskId: t.id, requestedBy: "someone-else") else {
            return XCTFail("expected pending approval")
        }
        XCTAssertEqual(second, first)

        guard case .approvalPending(let unrelated) = try f.board.requestSpawn(taskId: other.id, requestedBy: "orch-session") else {
            return XCTFail("expected pending approval")
        }
        XCTAssertNotEqual(unrelated.id, first.id)
        XCTAssertEqual(try f.approvals.pending(projectId: f.project.id).map(\.id), [first.id, unrelated.id])
        XCTAssertEqual(try f.tasks.get(t.id)?.column, .ready)
    }

    func testAutonomyOnProceedsWithoutApproval() throws {
        let f = try Fixture.make()
        try f.setAutonomy(true)
        let t = try f.task("t", column: .ready)
        XCTAssertEqual(try f.board.requestSpawn(taskId: t.id, requestedBy: "orch"), .proceed)
        XCTAssertEqual(try f.approvals.pending(projectId: f.project.id), [])
    }

    func testFlaggedReadyTaskStillGatesNormally() throws {
        let f = try Fixture.make()
        try f.setAutonomy(true)
        let t = try f.task("t", column: .ready)
        try f.tasks.setFailed(t.id, true, reason: "earlier attempt")
        try f.tasks.setBlocked(t.id, true, reason: "waiting")
        XCTAssertEqual(try f.board.requestSpawn(taskId: t.id, requestedBy: "orch"), .proceed)
    }

    func testDeniedApprovalAllowsAFreshRequest() throws {
        let f = try Fixture.make()
        let t = try f.task("t", column: .ready)
        guard case .approvalPending(let first) = try f.board.requestSpawn(taskId: t.id, requestedBy: "orch") else {
            return XCTFail("expected pending approval")
        }
        try f.board.resolveApproval(first.id, approved: false, by: "human", reason: "not now")
        guard case .approvalPending(let second) = try f.board.requestSpawn(taskId: t.id, requestedBy: "orch") else {
            return XCTFail("expected pending approval")
        }
        XCTAssertNotEqual(second.id, first.id)
    }
}

final class ResolveApprovalTests: XCTestCase {
    func testApprovedQueuesDecisionReportNamingTask() throws {
        let f = try Fixture.make()
        let t = try f.task("Wire the thing", column: .ready)
        guard case .approvalPending(let approval) = try f.board.requestSpawn(taskId: t.id, requestedBy: "orch") else {
            return XCTFail("expected pending approval")
        }
        XCTAssertEqual(try f.reports.unconsumedCount(projectId: f.project.id), 0)

        let resolved = try f.board.resolveApproval(approval.id, approved: true, by: "human")
        XCTAssertEqual(resolved.id, approval.id)
        XCTAssertEqual(resolved.resolution, .approved)
        XCTAssertFalse(resolved.isPending)
        XCTAssertEqual(try f.approvals.get(approval.id), resolved)

        let reports = try f.reports.unconsumed(projectId: f.project.id)
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0].kind, .decision)
        XCTAssertEqual(reports[0].taskId, t.id)
        XCTAssertNil(reports[0].sessionId)
        XCTAssertTrue(reports[0].body.hasPrefix("spawn approved for task \(t.id) (Wire the thing)"), reports[0].body)
        XCTAssertTrue(reports[0].body.contains("Resolved by: human"), reports[0].body)
        XCTAssertEqual(try f.approvals.pending(projectId: f.project.id), [])
    }

    func testDeniedQueuesDecisionReportWithReason() throws {
        let f = try Fixture.make()
        let t = try f.task("Risky", column: .ready)
        guard case .approvalPending(let approval) = try f.board.requestSpawn(taskId: t.id, requestedBy: "orch") else {
            return XCTFail("expected pending approval")
        }

        let resolved = try f.board.resolveApproval(approval.id, approved: false, by: "human", reason: "too expensive")
        XCTAssertEqual(resolved.resolution, .denied)

        let reports = try f.reports.unconsumed(projectId: f.project.id)
        XCTAssertEqual(reports.map(\.kind), [.decision])
        XCTAssertTrue(reports[0].body.hasPrefix("spawn denied for task \(t.id) (Risky): too expensive"), reports[0].body)
        XCTAssertEqual(try f.tasks.get(t.id)?.column, .ready)
    }

    func testResolveTwiceThrowsAndQueuesNoSecondReport() throws {
        let f = try Fixture.make()
        let t = try f.task("t", column: .ready)
        let approval = try f.approvals.create(projectId: f.project.id, kind: .spawn, taskId: t.id, epicId: nil, requestedBy: "orch", reason: nil)
        try f.board.resolveApproval(approval.id, approved: true, by: "human")
        XCTAssertThrowsError(try f.board.resolveApproval(approval.id, approved: false, by: "human")) { error in
            XCTAssertEqual(error as? BoardError, .approvalAlreadyResolved(approval.id))
        }
        XCTAssertThrowsError(try f.board.resolveApproval("missing", approved: true, by: "human")) { error in
            XCTAssertEqual(error as? BoardError, .approvalNotFound("missing"))
        }
        XCTAssertEqual(try f.reports.unconsumedCount(projectId: f.project.id), 1)
    }

    func testIntegrationApprovalWithoutTaskStillReports() throws {
        let f = try Fixture.make()
        let approval = try f.approvals.create(projectId: f.project.id, kind: .integration, taskId: nil, epicId: nil, requestedBy: "orch", reason: nil)
        try f.board.resolveApproval(approval.id, approved: true, by: "human")
        let reports = try f.reports.unconsumed(projectId: f.project.id)
        XCTAssertEqual(reports.count, 1)
        XCTAssertNil(reports[0].taskId)
        XCTAssertTrue(reports[0].body.hasPrefix("integration approved"), reports[0].body)
    }
}

final class ReportConsumeAllTests: XCTestCase {
    func testConsumeAllReturnsUnconsumedInOrderAndScopedToProject() throws {
        let f = try Fixture.make()
        let other = try f.projects.register(name: "Other", repoPath: "/other", baseBranch: "main", worktreeRoot: "/w", memoryDir: nil)
        let r1 = try f.reports.insert(projectId: f.project.id, taskId: nil, sessionId: nil, kind: .complete, body: "one")
        let r2 = try f.reports.insert(projectId: f.project.id, taskId: nil, sessionId: nil, kind: .blocked, body: "two")
        let already = try f.reports.insert(projectId: f.project.id, taskId: nil, sessionId: nil, kind: .proposal, body: "old")
        try f.reports.consume(ids: [XCTUnwrap(already.id)])
        let elsewhere = try f.reports.insert(projectId: other.id, taskId: nil, sessionId: nil, kind: .complete, body: "other")
        XCTAssertEqual(try f.reports.unconsumedCount(projectId: f.project.id), 2)

        let consumed = try f.reports.consumeAll(projectId: f.project.id)
        XCTAssertEqual(consumed.map(\.id), [r1.id, r2.id])
        XCTAssertEqual(consumed.map(\.body), ["one", "two"])
        XCTAssertTrue(consumed.allSatisfy { !$0.isConsumed }, "returns the rows as they were before consumption")

        XCTAssertEqual(try f.reports.unconsumedCount(projectId: f.project.id), 0)
        XCTAssertEqual(try f.reports.unconsumed(projectId: f.project.id), [])
        XCTAssertTrue(try XCTUnwrap(f.reports.get(XCTUnwrap(r1.id))).isConsumed)
        XCTAssertTrue(try XCTUnwrap(f.reports.get(XCTUnwrap(r2.id))).isConsumed)
        XCTAssertEqual(try f.reports.unconsumedCount(projectId: other.id), 1)
        XCTAssertFalse(try XCTUnwrap(f.reports.get(XCTUnwrap(elsewhere.id))).isConsumed)

        XCTAssertEqual(try f.reports.consumeAll(projectId: f.project.id), [])
    }
}

final class OrchestratorSessionTests: XCTestCase {
    func testOrchestratorReturnsNewestOrchestratorForProject() throws {
        let f = try Fixture.make()
        let other = try f.projects.register(name: "Other", repoPath: "/other", baseBranch: "main", worktreeRoot: "/w", memoryDir: nil)
        XCTAssertNil(try f.sessions.orchestrator(projectId: f.project.id))

        try f.sessions.insert(f.session("worker", role: .worker))
        XCTAssertNil(try f.sessions.orchestrator(projectId: f.project.id))

        try f.sessions.insert(AgentSession(sessionId: "orch-old", projectId: f.project.id, taskId: nil, role: .orchestrator, cwd: "/repo", state: .stopped, startedAt: 1000))
        try f.sessions.insert(AgentSession(sessionId: "orch-new", projectId: f.project.id, taskId: nil, role: .orchestrator, cwd: "/repo", state: .running, startedAt: 2000))
        try f.sessions.insert(AgentSession(sessionId: "orch-elsewhere", projectId: other.id, taskId: nil, role: .orchestrator, cwd: "/repo", state: .running, startedAt: 3000))

        let orch = try XCTUnwrap(f.sessions.orchestrator(projectId: f.project.id))
        XCTAssertEqual(orch.sessionId, "orch-new")
        XCTAssertEqual(orch.role, .orchestrator)
        XCTAssertNil(orch.taskId)
        XCTAssertEqual(try f.sessions.orchestrator(projectId: other.id)?.sessionId, "orch-elsewhere")
    }
}
