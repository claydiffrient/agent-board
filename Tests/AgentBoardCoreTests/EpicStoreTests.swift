import Foundation
import XCTest
@testable import AgentBoardCore

extension Fixture {
    var epics: EpicStore { EpicStore(db) }
}

final class EpicStoreTests: XCTestCase {
    func testCreateNamesBranchAfterIdAndStartsInPlanning() throws {
        let f = try Fixture.make()
        let epic = try f.epics.create(projectId: f.project.id, title: "Ship search", goal: "make it fast")

        XCTAssertEqual(epic.branch, "agentboard/epic-\(epic.id)")
        XCTAssertEqual(epic.state, .planning)
        XCTAssertEqual(epic.title, "Ship search")
        XCTAssertEqual(epic.goal, "make it fast")
        XCTAssertEqual(epic.projectId, f.project.id)
        XCTAssertGreaterThan(epic.createdAt, 0)
        XCTAssertEqual(try f.epics.get(epic.id), epic)
    }

    func testGetReturnsNilForUnknownId() throws {
        let f = try Fixture.make()
        XCTAssertNil(try f.epics.get("missing"))
    }

    func testListIsScopedToProjectAndOrderedByCreation() throws {
        let f = try Fixture.make()
        let other = try f.projects.register(
            name: "Other", repoPath: "/tmp/other-\(UUID().uuidString)", baseBranch: "main",
            worktreeRoot: "/tmp/other-worktrees", memoryDir: nil
        )
        let first = try f.epics.create(projectId: f.project.id, title: "first", goal: nil)
        let second = try f.epics.create(projectId: f.project.id, title: "second", goal: nil)
        let elsewhere = try f.epics.create(projectId: other.id, title: "elsewhere", goal: nil)

        XCTAssertEqual(try f.epics.list(projectId: f.project.id).map(\.id), [first.id, second.id])
        XCTAssertEqual(try f.epics.list(projectId: other.id).map(\.id), [elsewhere.id])
    }

    func testSetStateWalksTheLifecycleAndThrowsForUnknownEpic() throws {
        let f = try Fixture.make()
        let epic = try f.epics.create(projectId: f.project.id, title: "e", goal: nil)

        for state: EpicState in [.active, .integrating, .done, .abandoned, .planning] {
            try f.epics.setState(epic.id, state)
            XCTAssertEqual(try f.epics.get(epic.id)?.state, state)
        }

        XCTAssertThrowsError(try f.epics.setState("missing", .active)) { error in
            XCTAssertEqual(error as? BoardError, .epicNotFound("missing"))
        }
    }

    func testObserveEmitsNewEpics() throws {
        let f = try Fixture.make()
        let sawSecond = expectation(description: "saw second epic")
        let cancellable = f.epics.observe(projectId: f.project.id).start(
            in: f.db.writer,
            onError: { XCTFail("\($0)") },
            onChange: { epics in
                if epics.map(\.title) == ["one", "two"] { sawSecond.fulfill() }
            }
        )
        try f.epics.create(projectId: f.project.id, title: "one", goal: nil)
        try f.epics.create(projectId: f.project.id, title: "two", goal: nil)
        wait(for: [sawSecond], timeout: 2)
        cancellable.cancel()
    }
}
