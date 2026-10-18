import AgentBoardCore
import AgentBoardRuntime
import Foundation
import XCTest
@testable import AgentBoard

/// SPEC §3.1 "Removing a worktree" and §5: the project's teardown hook on accept, and what the
/// acceptance decision report says when cleanup does not go to plan.
@MainActor
final class WorktreeTeardownHookTests: XCTestCase {
    private var fixture: SupervisorFixture!

    override func setUp() async throws {
        fixture = try SupervisorFixture.make(gitRepo: true)
    }

    override func tearDown() async throws {
        await fixture.supervisor.waitForTeardowns()
        await fixture.cleanUp()
        fixture = nil
    }

    func testAcceptRunsTheHookInTheWorktreeBeforeRemovingIt() async throws {
        let marker = fixture.supportDir.appendingPathComponent("teardown-marker")
        try setTeardown("{ pwd -P; git rev-parse --show-toplevel; } > '\(marker.path)'")
        let task = try makeTask()
        let worktree = try XCTUnwrap(try fixture.worktreeWorker(task: task).worktreePath)
        let resolved = try XCTUnwrap(realpath(worktree, nil).map { String(cString: $0) })

        try await fixture.supervisor.accept(taskId: task.id)
        await fixture.supervisor.waitForTeardowns()

        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree))
        let lines = try String(contentsOf: marker, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, [resolved, resolved], "the hook did not run in the worktree while git still had it")
    }

    func testAFailingHookIsRecordedOnTheTaskAndInTheAcceptanceReport() async throws {
        try setTeardown("echo output-base-locked; exit 7")
        let task = try makeTask()
        let worktree = try XCTUnwrap(try fixture.worktreeWorker(task: task).worktreePath)

        try await fixture.supervisor.accept(taskId: task.id)
        await fixture.supervisor.waitForTeardowns()

        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree), "a failing hook blocked removal")
        let progress = try ProgressStore(fixture.db).list(taskId: task.id).map(\.text)
        XCTAssertTrue(progress.contains { $0.hasPrefix(Board.worktreeCleanupLead) && $0.contains("exited 7") }, "\(progress)")
        let report = try acceptanceReport(task)
        XCTAssertTrue(report.body.contains("exited 7"), report.body)
        XCTAssertTrue(report.body.contains("output-base-locked"), report.body)
    }

    /// The orphan reaper sees an accepted task's worktree as an orphan while its hook is still running.
    func testReconcileDuringASlowAcceptHookNeitherRunsItAgainNorReportsACleanupFinding() async throws {
        let marker = fixture.supportDir.appendingPathComponent("teardown-marker")
        try setTeardown("echo ran >> '\(marker.path)'; sleep 2")
        let task = try makeTask()
        let worktree = try XCTUnwrap(try fixture.worktreeWorker(task: task).worktreePath)

        try await fixture.supervisor.accept(taskId: task.id)
        let started = Date()
        while !FileManager.default.fileExists(atPath: marker.path), Date().timeIntervalSince(started) < 10 {
            try await _Concurrency.Task.sleep(nanoseconds: 50_000_000)
        }
        await fixture.supervisor.reconcile(projectId: fixture.project.id)
        await fixture.supervisor.waitForTeardowns()

        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree))
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "ran\n", "the hook ran more than once")
        let progress = try ProgressStore(fixture.db).list(taskId: task.id).map(\.text)
        XCTAssertFalse(progress.contains { $0.hasPrefix(Board.worktreeCleanupLead) }, "\(progress)")
        let reports = try ReportStore(fixture.db).unconsumed(projectId: fixture.project.id).map(\.body)
        XCTAssertFalse(reports.contains { $0.contains(Board.worktreeCleanupLead) }, "\(reports)")
    }

    /// Task 51c0040b kept its worktree over a `yarn.lock` its setup left behind, and nothing said so.
    func testAcceptNamesTheDirtyPathsOfAKeptWorktreeAndDoesNotRunTheHookThere() async throws {
        let marker = fixture.supportDir.appendingPathComponent("teardown-marker")
        try setTeardown("touch '\(marker.path)'")
        let task = try makeTask()
        let worktree = try XCTUnwrap(try fixture.worktreeWorker(task: task).worktreePath)
        try "{}\n".write(
            to: URL(fileURLWithPath: worktree).appendingPathComponent("yarn.lock"), atomically: true, encoding: .utf8
        )

        try await fixture.supervisor.accept(taskId: task.id)
        await fixture.supervisor.waitForTeardowns()

        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "the hook ran on a worktree that was kept")
        let report = try acceptanceReport(task)
        XCTAssertTrue(report.body.contains("kept worktree \(worktree): it has uncommitted changes in yarn.lock"), report.body)
    }

    private func acceptanceReport(_ task: BoardTask) throws -> Report {
        try XCTUnwrap(
            try ReportStore(fixture.db).unconsumed(projectId: fixture.project.id)
                .first { $0.kind == .decision && $0.body.hasPrefix("Task \(task.id) (\(task.title)) was accepted into done") }
        )
    }

    private func setTeardown(_ command: String) throws {
        var settings = try XCTUnwrap(try ProjectStore(fixture.db).get(fixture.project.id)).settings
        settings.worktreeTeardownCommand = command
        try ProjectStore(fixture.db).updateSettings(fixture.project.id, settings)
    }

    private func makeTask() throws -> BoardTask {
        try fixture.tasks.create(
            projectId: fixture.project.id, title: "Do the thing", body: nil, acceptance: nil,
            priority: nil, column: .ready, origin: .human, epicId: nil
        )
    }
}
