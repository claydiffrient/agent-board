import Foundation
import XCTest
@testable import AgentBoardCore

final class ReportStoreTests: XCTestCase {
    func testUnconsumedThenConsume() throws {
        let f = try Fixture.make()
        let t = try f.task("t")
        let r1 = try f.reports.insert(projectId: f.project.id, taskId: t.id, sessionId: nil, kind: .complete, body: "one")
        let r2 = try f.reports.insert(projectId: f.project.id, taskId: nil, sessionId: nil, kind: .proposal, body: "two")
        let r3 = try f.reports.insert(projectId: f.project.id, taskId: nil, sessionId: nil, kind: .blocked, body: "three")
        let id1 = try XCTUnwrap(r1.id)
        let id2 = try XCTUnwrap(r2.id)
        let id3 = try XCTUnwrap(r3.id)

        XCTAssertEqual(try f.reports.unconsumed(projectId: f.project.id).map(\.id), [id1, id2, id3])
        XCTAssertEqual(try f.reports.get(id2)?.body, "two")

        try f.reports.consume(ids: [id1, id3])
        let remaining = try f.reports.unconsumed(projectId: f.project.id)
        XCTAssertEqual(remaining.map(\.id), [id2])
        XCTAssertTrue(try XCTUnwrap(f.reports.get(id1)).isConsumed)
        XCTAssertFalse(try XCTUnwrap(f.reports.get(id2)).isConsumed)

        try f.reports.consume(ids: [])
        XCTAssertEqual(try f.reports.unconsumed(projectId: f.project.id).count, 1)
    }

    func testObserveUnconsumedShrinksAfterConsume() throws {
        let f = try Fixture.make()
        let r = try f.reports.insert(projectId: f.project.id, taskId: nil, sessionId: nil, kind: .complete, body: "x")
        let emptied = expectation(description: "emptied")
        let cancellable = f.reports.observeUnconsumed(projectId: f.project.id).start(
            in: f.db.writer,
            onError: { XCTFail("\($0)") },
            onChange: { reports in
                if reports.isEmpty { emptied.fulfill() }
            }
        )
        try f.reports.consume(ids: [XCTUnwrap(r.id)])
        wait(for: [emptied], timeout: 2)
        cancellable.cancel()
    }
}

final class ProgressStoreTests: XCTestCase {
    func testAppendListNewestFirstAndLatest() throws {
        let f = try Fixture.make()
        let t = try f.task("t")
        let first = try f.progress.append(taskId: t.id, sessionId: nil, kind: .note, text: "first")
        let second = try f.progress.append(taskId: t.id, sessionId: nil, kind: .tool, text: "Bash")
        let third = try f.progress.append(taskId: t.id, sessionId: nil, kind: .status, text: "running tests")
        XCTAssertNotNil(first.id)
        XCTAssertEqual(try f.progress.list(taskId: t.id).map(\.id), [third.id, second.id, first.id])
        XCTAssertEqual(try f.progress.list(taskId: t.id, limit: 2).map(\.text), ["running tests", "Bash"])
        XCTAssertEqual(try f.progress.latest(taskId: t.id), third)
        XCTAssertNil(try f.progress.latest(taskId: "other"))
    }

    func testAppendRequiresExistingTask() throws {
        let f = try Fixture.make()
        XCTAssertThrowsError(try f.progress.append(taskId: "missing", sessionId: nil, kind: .note, text: "x"))
    }
}

final class HookEventStoreTests: XCTestCase {
    func testAppendRecentAndPrune() throws {
        let f = try Fixture.make()
        try f.hooks.append(sessionId: "s1", event: "PostToolUse", payload: "{}")
        try f.hooks.append(sessionId: "s1", event: "Stop", payload: "{\"a\":1}")
        try f.hooks.append(sessionId: "s2", event: "Stop", payload: "{}")
        try f.hooks.append(sessionId: nil, event: "SessionStart", payload: "{}")

        let recent = try f.hooks.recent(sessionId: "s1")
        XCTAssertEqual(recent.map(\.event), ["Stop", "PostToolUse"])
        XCTAssertEqual(try f.hooks.recent(sessionId: "s1", limit: 1).map(\.event), ["Stop"])

        try f.hooks.prune(olderThan: Int64.nowMillis + 1)
        XCTAssertEqual(try f.hooks.recent(sessionId: "s1").count, 0)
        XCTAssertEqual(try f.hooks.recent(sessionId: "s2").count, 0)
    }
}
