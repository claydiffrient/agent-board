import Foundation
import XCTest
@testable import AgentBoardCore

final class TaskStoreTests: XCTestCase {
    func testCreateAppendsOrderingWithinColumn() throws {
        let f = try Fixture.make()
        let a = try f.task("a")
        let b = try f.task("b")
        let c = try f.task("c", column: .ready)
        XCTAssertEqual(a.ordering, 1)
        XCTAssertEqual(b.ordering, 2)
        XCTAssertEqual(c.ordering, 1)
        XCTAssertEqual(a.origin, .human)
        XCTAssertFalse(a.blocked)
        XCTAssertFalse(a.failed)
    }

    func testListOrdersByColumnThenOrdering() throws {
        let f = try Fixture.make()
        let done = try f.task("done", column: .done)
        let ready = try f.task("ready", column: .ready)
        let backlog2 = try f.task("b2")
        let backlog1 = try f.task("b1")
        try f.tasks.move(backlog1.id, to: .backlog, before: backlog2.id)
        let proposed = try f.task("p", column: .proposed, origin: .workerProposal)

        let ids = try f.tasks.list(projectId: f.project.id).map(\.id)
        XCTAssertEqual(ids, [proposed.id, backlog1.id, backlog2.id, ready.id, done.id])

        XCTAssertEqual(try f.tasks.list(projectId: f.project.id, column: .backlog).map(\.id), [backlog1.id, backlog2.id])
    }

    func testListFiltersByEpic() throws {
        let f = try Fixture.make()
        let epic = Epic(id: Epic.newId(), projectId: f.project.id, title: "E", goal: nil, branch: "agentboard/epic-x", state: .planning, createdAt: .nowMillis)
        try f.db.writer.write { try epic.insert($0) }
        let inEpic = try f.tasks.create(projectId: f.project.id, title: "in", body: nil, acceptance: nil, priority: nil, column: .backlog, origin: .orchestrator, epicId: epic.id)
        try f.task("out")
        XCTAssertEqual(try f.tasks.list(projectId: f.project.id, epicId: epic.id).map(\.id), [inEpic.id])
    }

    func testMoveToEndOfColumn() throws {
        let f = try Fixture.make()
        let a = try f.task("a")
        let b = try f.task("b", column: .ready)
        try f.tasks.move(a.id, to: .ready)
        let moved = try XCTUnwrap(f.tasks.get(a.id))
        XCTAssertEqual(moved.column, .ready)
        XCTAssertEqual(moved.ordering, b.ordering + 1)
        XCTAssertGreaterThanOrEqual(moved.updatedAt, a.updatedAt)
    }

    func testMoveBeforeUsesMidpoint() throws {
        let f = try Fixture.make()
        let a = try f.task("a")
        let b = try f.task("b")
        let c = try f.task("c")
        let mover = try f.task("m", column: .ready)

        try f.tasks.move(mover.id, to: .backlog, before: c.id)
        XCTAssertEqual(try f.tasks.get(mover.id)?.ordering, (b.ordering + c.ordering) / 2)
        XCTAssertEqual(try f.tasks.list(projectId: f.project.id, column: .backlog).map(\.id), [a.id, b.id, mover.id, c.id])

        try f.tasks.move(mover.id, to: .backlog, before: a.id)
        XCTAssertEqual(try f.tasks.get(mover.id)?.ordering, a.ordering - 1)
        XCTAssertEqual(try f.tasks.list(projectId: f.project.id, column: .backlog).map(\.id), [mover.id, a.id, b.id, c.id])
    }

    func testMoveBeforeIgnoresAnchorInOtherColumn() throws {
        let f = try Fixture.make()
        let a = try f.task("a")
        let anchor = try f.task("anchor", column: .done)
        try f.tasks.move(a.id, to: .ready, before: anchor.id)
        let moved = try XCTUnwrap(f.tasks.get(a.id))
        XCTAssertEqual(moved.column, .ready)
        XCTAssertEqual(moved.ordering, 1)
    }

    func testMoveUnknownTaskThrows() throws {
        let f = try Fixture.make()
        XCTAssertThrowsError(try f.tasks.move("nope", to: .ready)) { error in
            XCTAssertEqual(error as? BoardError, .taskNotFound("nope"))
        }
    }

    func testUpdateBumpsUpdatedAt() throws {
        let f = try Fixture.make()
        var a = try f.task("a")
        a.title = "renamed"
        a.updatedAt = 0
        try f.tasks.update(a)
        let fetched = try XCTUnwrap(f.tasks.get(a.id))
        XCTAssertEqual(fetched.title, "renamed")
        XCTAssertGreaterThan(fetched.updatedAt, 0)
    }

    func testSetDepsReplacesAndIgnoresSelf() throws {
        let f = try Fixture.make()
        let a = try f.task("a")
        let b = try f.task("b")
        let c = try f.task("c")
        try f.tasks.setDeps(c.id, dependsOn: [a.id, b.id, c.id, a.id])
        XCTAssertEqual(try f.tasks.deps(of: c.id).sorted(), [a.id, b.id].sorted())
        XCTAssertEqual(try f.tasks.dependents(of: a.id), [c.id])
        try f.tasks.setDeps(c.id, dependsOn: [b.id])
        XCTAssertEqual(try f.tasks.deps(of: c.id), [b.id])
        XCTAssertEqual(try f.tasks.dependents(of: a.id), [])
    }

    func testRefreshReadinessMovesBothDirections() throws {
        let f = try Fixture.make()
        let dep = try f.task("dep")
        let dependent = try f.task("dependent")
        let free = try f.task("free")
        try f.tasks.setDeps(dependent.id, dependsOn: [dep.id])

        var changed = try f.tasks.refreshReadiness(projectId: f.project.id)
        XCTAssertEqual(Set(changed), [dep.id, free.id])
        XCTAssertEqual(try f.tasks.get(dep.id)?.column, .ready)
        XCTAssertEqual(try f.tasks.get(free.id)?.column, .ready)
        XCTAssertEqual(try f.tasks.get(dependent.id)?.column, .backlog)

        try f.tasks.move(dep.id, to: .done)
        changed = try f.tasks.refreshReadiness(projectId: f.project.id)
        XCTAssertEqual(changed, [dependent.id])
        XCTAssertEqual(try f.tasks.get(dependent.id)?.column, .ready)

        try f.tasks.move(dep.id, to: .ready)
        changed = try f.tasks.refreshReadiness(projectId: f.project.id)
        XCTAssertEqual(changed, [dependent.id])
        XCTAssertEqual(try f.tasks.get(dependent.id)?.column, .backlog)

        XCTAssertEqual(try f.tasks.refreshReadiness(projectId: f.project.id), [])
    }

    func testRefreshReadinessLeavesOtherColumnsAlone() throws {
        let f = try Fixture.make()
        let proposed = try f.task("p", column: .proposed)
        let running = try f.task("r", column: .running)
        XCTAssertEqual(try f.tasks.refreshReadiness(projectId: f.project.id), [])
        XCTAssertEqual(try f.tasks.get(proposed.id)?.column, .proposed)
        XCTAssertEqual(try f.tasks.get(running.id)?.column, .running)
    }

    func testBlockedAndFailedFlags() throws {
        let f = try Fixture.make()
        let a = try f.task("a")
        try f.tasks.setBlocked(a.id, true, reason: "waiting on permission")
        var t = try XCTUnwrap(f.tasks.get(a.id))
        XCTAssertTrue(t.blocked)
        XCTAssertEqual(t.blockedReason, "waiting on permission")
        try f.tasks.setBlocked(a.id, false, reason: "ignored")
        t = try XCTUnwrap(f.tasks.get(a.id))
        XCTAssertFalse(t.blocked)
        XCTAssertNil(t.blockedReason)

        try f.tasks.setFailed(a.id, true, reason: "token cap")
        t = try XCTUnwrap(f.tasks.get(a.id))
        XCTAssertTrue(t.failed)
        XCTAssertEqual(t.failureReason, "token cap")
    }

    func testDeleteCleansDependencyEdges() throws {
        let f = try Fixture.make()
        let a = try f.task("a")
        let b = try f.task("b")
        try f.tasks.setDeps(b.id, dependsOn: [a.id])
        try f.progress.append(taskId: a.id, sessionId: nil, kind: .note, text: "x")
        try f.tasks.delete(a.id)
        XCTAssertNil(try f.tasks.get(a.id))
        XCTAssertEqual(try f.tasks.deps(of: b.id), [])
    }

    func testObserveEmitsOnChange() throws {
        let f = try Fixture.make()
        let expectation = expectation(description: "two tasks")
        let cancellable = f.tasks.observe(projectId: f.project.id).start(
            in: f.db.writer,
            onError: { XCTFail("\($0)") },
            onChange: { tasks in
                if tasks.count == 2 { expectation.fulfill() }
            }
        )
        try f.task("a")
        try f.task("b")
        wait(for: [expectation], timeout: 2)
        cancellable.cancel()
    }
}
