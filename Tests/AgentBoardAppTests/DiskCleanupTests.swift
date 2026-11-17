import AgentBoardCore
import AgentBoardRuntime
import Foundation
import XCTest
@testable import AgentBoard

private final class LowDisk: DiskSpaceMeasuring, @unchecked Sendable {
    func volumes(holding paths: [URL]) -> [VolumeSpace] {
        [VolumeSpace(mountPoint: "/Volumes/Work", name: "Work", availableBytes: 12_300_000_000)]
    }
}

/// Each measurement reads 10 GB more than the last.
private final class Measurements: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> [VolumeSpace] {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return [VolumeSpace(mountPoint: "/Volumes/Work", name: "Work", availableBytes: Int64(count) * 10_000_000_000)]
    }
}

@MainActor
final class DiskCleanupTests: XCTestCase {
    private var fixture: SupervisorFixture!
    private var banners: [String] = []

    override func setUp() async throws {
        fixture = try SupervisorFixture.make(gitRepo: true)
        banners = []
        fixture.supervisor.postBanner = { [weak self] title, body, _ in self?.banners.append("\(title): \(body)") }
        let measurements = Measurements()
        fixture.supervisor.measureVolumes = { _ in measurements.next() }
    }

    override func tearDown() async throws {
        await fixture.cleanUp()
        fixture = nil
    }

    func testALowDiskEventSweepsEveryProjectThenRunsEachCommandInTurnAndNotifiesOnce() async throws {
        let dir = fixture.supportDir
        let log = dir.appendingPathComponent("log").path
        let started = dir.appendingPathComponent("started").path
        let gate = dir.appendingPathComponent("gate").path

        let zetaRepo = dir.appendingPathComponent("repo2")
        try SupervisorFixture.initRepo(at: zetaRepo)
        let zeta = try ProjectStore(fixture.db).register(
            name: "Zeta", repoPath: zetaRepo.path, baseBranch: "main",
            worktreeRoot: dir.appendingPathComponent("worktrees2").path, memoryDir: nil
        )
        let demoDone = try finishedWorktree(in: fixture.project, manager: fixture.manager)
        let zetaManager = WorktreeManager(
            repoPath: zetaRepo, worktreeRoot: URL(fileURLWithPath: zeta.worktreeRoot),
            hookSettingsURL: dir.appendingPathComponent("no-hooks.json"), attribution: .ledger(TaskCommitStore(fixture.db))
        )
        let zetaDone = try finishedWorktree(in: zeta, manager: zetaManager)
        let zetaDirty = try finishedWorktree(in: zeta, manager: zetaManager)
        try "unsaved\n".write(toFile: zetaDirty + "/scratch.txt", atomically: true, encoding: .utf8)

        try setCleanup(fixture.project, """
            touch '\(started)'; while [ ! -e '\(gate)' ]; do sleep 0.05; done
            [ ! -e '\(demoDone)' ] && [ ! -e '\(zetaDone)' ] && echo demo >> '\(log)'
            """)
        try setCleanup(zeta, "echo zeta >> '\(log)'; exit 3")

        fixture.supervisor.cleanUpOnLowDiskSpace()
        fixture.supervisor.diskSpace = DiskSpaceMonitor(measurer: LowDisk(), settings: { .defaults })
        fixture.supervisor.checkDiskSpace(try ProjectStore(fixture.db).list())
        try await waitUntil("the first cleanup command started") { FileManager.default.fileExists(atPath: started) }

        fixture.supervisor.diskSpace = DiskSpaceMonitor(measurer: LowDisk(), settings: { .defaults })
        fixture.supervisor.checkDiskSpace(try ProjectStore(fixture.db).list())
        for _ in 0..<20 { await _Concurrency.Task.yield() }
        try await _Concurrency.Task.sleep(nanoseconds: 200_000_000)
        FileManager.default.createFile(atPath: gate, contents: nil)
        try await waitUntil("the cleanup finished") { self.banners.count == 3 && self.fixture.supervisor.diskCleanupRun == nil }

        XCTAssertEqual(try String(contentsOfFile: log, encoding: .utf8), "demo\nzeta\n")
        XCTAssertEqual(banners.last, """
            Disk cleanup finished: Work: 10.0 GB free before, 30.0 GB after.
            Removed 2 worktrees, kept 1.
            `echo zeta >> '\(log)'; exit 3` in Zeta exited 3.
            """)
        XCTAssertEqual(banners.filter { $0.hasPrefix("Disk cleanup finished") }.count, 1, "\(banners)")

        for project in [fixture.project, zeta] {
            let reports = try fixture.reports.unconsumed(projectId: project.id)
            XCTAssertEqual(reports.map(\.kind), [.decision], "\(project.name): \(reports.map(\.body))")
            XCTAssertTrue(reports.first?.body.contains("The cleanup command") == true, reports.first?.body ?? "")
        }
        let zetaReport = try XCTUnwrap(try fixture.reports.unconsumed(projectId: zeta.id).first).body
        XCTAssertTrue(zetaReport.contains(zetaDone) && zetaReport.contains(zetaDirty), zetaReport)
    }

    func testCleanUpNowRunsTheSequenceThroughTheProtocol() async throws {
        let done = try finishedWorktree(in: fixture.project, manager: fixture.manager)
        let supervisor: any WorkerSupervising = fixture.supervisor

        await supervisor.cleanUpDiskNow()

        XCTAssertFalse(FileManager.default.fileExists(atPath: done))
        XCTAssertEqual(banners, ["Disk cleanup finished: Work: 10.0 GB free before, 30.0 GB after.\nRemoved 1 worktree, kept 0."])
        let report = try XCTUnwrap(try fixture.reports.unconsumed(projectId: fixture.project.id).first)
        XCTAssertTrue(report.body.hasPrefix("Clean up now swept"), report.body)
    }

    private func finishedWorktree(in project: Project, manager: WorktreeManager) throws -> String {
        let task = try fixture.tasks.create(
            projectId: project.id, title: "Done", body: nil, acceptance: nil,
            priority: nil, column: .ready, origin: .human, epicId: nil
        )
        try fixture.db.writer.write { db in
            try db.execute(sql: "UPDATE task SET column_name = ? WHERE id = ?", arguments: [TaskColumn.done, task.id])
        }
        var path = try manager.create(name: task.id, branch: "agentboard/\(task.id)", base: project.baseBranch).path
        if path.hasPrefix("/private/var/") { path = String(path.dropFirst("/private".count)) }
        try fixture.sessions.insert(AgentSession(
            sessionId: "session-\(UUID().uuidString)", projectId: project.id, taskId: task.id,
            role: .worker, worktreePath: path, branch: "agentboard/\(task.id)", cwd: path, state: .completed, attempt: 1
        ))
        return path
    }

    private func setCleanup(_ project: Project, _ command: String) throws {
        var settings = project.settings
        settings.cleanupCommand = command
        try ProjectStore(fixture.db).updateSettings(project.id, settings)
    }

    private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out waiting until \(what)") }
            try await _Concurrency.Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
