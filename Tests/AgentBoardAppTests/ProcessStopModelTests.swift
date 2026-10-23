import AgentBoardCore
import AgentBoardRuntime
import Darwin
import Foundation
import XCTest
@testable import AgentBoard

/// The process view's Stop on a session's host (SPEC §8.7): never a raw signal, always the
/// session Stop, so the row, the grant and the task stay consistent.
@MainActor
final class ProcessStopModelTests: XCTestCase {
    private var fixture: SupervisorFixture!
    private var host: Process?

    override func setUp() async throws {
        fixture = try SupervisorFixture.make()
    }

    override func tearDown() async throws {
        host?.terminate()
        await fixture.cleanUp()
        fixture = nil
    }

    func testStoppingAWorkersHostRunsTheSessionStopAndLogsItOnTheTask() async throws {
        let worker = try fixture.workerAtWork()
        let session = try XCTUnwrap(fixture.sessions.get(worker.sessionId))
        let sleep = Process()
        sleep.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleep.arguments = ["600"]
        try sleep.run()
        host = sleep
        let pid = sleep.processIdentifier
        let shortId = try XCTUnwrap(session.shortId)
        await fixture.runtime.host(pid, shortId: shortId)
        await fixture.runtime.setListed([AgentInfo(
            id: shortId, cwd: session.cwd, kind: "background", sessionId: session.sessionId, pid: Int(pid)
        )])
        let table = ProcessTable.current()
        let inventory = ProcessInventory.build(
            table: table,
            roots: [InventoryRoot(pid: pid, owner: SessionInventoryRoots.owner(of: session))],
            facts: { _ in nil }
        )
        let model = ProcessStopModel(
            db: fixture.db, supervisor: fixture.supervisor,
            hosts: { [pid: session.sessionId] }, isClaude: { _ in false }
        )

        await model.stop(try XCTUnwrap(table.identity(of: pid)), in: inventory)

        XCTAssertEqual(model.message, "Stopped the session")
        let stopped = await fixture.runtime.stopped
        XCTAssertEqual(stopped, [shortId], "the host was not stopped through claude stop")
        XCTAssertEqual(try fixture.sessions.get(worker.sessionId)?.state, .stopped)
        XCTAssertFalse(try fixture.grants.hasLiveGrant(sessionId: worker.sessionId), "the grant outlived the stop")
        let logged = try ProgressStore(fixture.db).list(taskId: worker.task.id).map(\.text)
        XCTAssertTrue(logged.contains { $0.contains("from the process view") }, "\(logged)")
    }
}

/// A failed `claude agents` read is shown, and retried on the next sample instead of cached.
final class SessionProcessRootsTests: XCTestCase {
    func testAFailedListingIsReportedAndNotCached() async throws {
        let calls = Counter()
        let roots = SessionProcessRoots(db: try AppDatabase.inMemory()) {
            if await calls.next() == 1 { throw AgentRuntimeError("claude agents failed") }
            return []
        }

        let failed = await roots.roots()
        let retried = await roots.roots()

        XCTAssertTrue(failed.sessionHostsUnavailable)
        XCTAssertFalse(retried.sessionHostsUnavailable)
        let count = await calls.count
        XCTAssertEqual(count, 2, "the failure was cached")
    }
}

private actor Counter {
    private(set) var count = 0

    func next() -> Int {
        count += 1
        return count
    }
}
