import AgentBoardCore
import AgentBoardRuntime
import Darwin
import Foundation
import XCTest
@testable import AgentBoard

/// SPEC §8.5: a worker's Bash tool runs each command in a shell that leads its own session, so it
/// survives the `claude` host's death reparented to launchd. Ending the session must reap it anyway.
@MainActor
final class SessionEndReapsProcessTreeTests: XCTestCase {
    private var fixture: SupervisorFixture!
    private var host: Process?
    private var leftovers: [pid_t] = []

    override func setUp() async throws {
        fixture = try SupervisorFixture.make()
    }

    override func tearDown() async throws {
        for pid in leftovers { kill(pid, SIGKILL) }
        host?.terminate()
        fixture.cleanUp()
        fixture = nil
    }

    func testStopWorkerKillsTheDetachedCommandTheSessionStarted() async throws {
        let python = "/usr/bin/python3"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python))
        let worker = try fixture.workerAtWork()
        let session = try XCTUnwrap(fixture.sessions.get(worker.sessionId))
        let worktree = URL(fileURLWithPath: try XCTUnwrap(session.worktreePath))
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        let pidFile = fixture.supportDir.appendingPathComponent("detached.pids")

        let fakeClaude = Process()
        fakeClaude.executableURL = URL(fileURLWithPath: python)
        fakeClaude.currentDirectoryURL = worktree
        fakeClaude.arguments = ["-c", """
            import os, sys, time
            if os.fork() == 0:
                os.setsid()
                os.execv("/bin/sh", ["/bin/sh", "-c", "/bin/sleep 600 & echo $$ $! > \\"$0\\"; wait", sys.argv[1]])
            time.sleep(600)
            """, pidFile.path]
        try fakeClaude.run()
        host = fakeClaude

        let detached = try await waitForPIDs(in: pidFile)
        leftovers = detached
        XCTAssertEqual(getsid(detached[0]), detached[0], "the fixture's shell must lead its own session, as the Bash tool's does")
        await fixture.runtime.host(fakeClaude.processIdentifier, shortId: try XCTUnwrap(session.shortId))
        await fixture.runtime.setListed([AgentInfo(
            id: session.shortId, cwd: worktree.path, kind: "background", sessionId: session.sessionId,
            pid: Int(fakeClaude.processIdentifier)
        )])

        try await fixture.supervisor.stopWorker(sessionId: worker.sessionId)

        for pid in detached {
            XCTAssertFalse(isRunning(pid), "pid \(pid), started by the session, outlived its end")
        }
    }

    private func waitForPIDs(in file: URL) async throws -> [pid_t] {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            let pids = ((try? String(contentsOf: file, encoding: .utf8)) ?? "")
                .split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) }
            if pids.count == 2 { return pids }
            try await _Concurrency.Task.sleep(for: .milliseconds(50))
        }
        throw FixtureError("the fake claude never started its detached command")
    }

    /// A zombie still answers `kill(pid, 0)`, so a reaped-but-unwaited child is read by its state.
    private func isRunning(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return info.pbi_status != UInt32(SZOMB)
    }
}
