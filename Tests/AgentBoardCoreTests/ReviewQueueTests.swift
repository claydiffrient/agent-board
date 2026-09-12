import XCTest
@testable import AgentBoardCore

final class ReviewQueueTests: XCTestCase {
    private func task(_ id: String, column: TaskColumn, ordering: Double, createdAt: Int64 = 0) -> BoardTask {
        BoardTask(
            id: id, projectId: "p", epicId: nil, title: id, body: nil, acceptance: nil,
            priority: nil, column: column, ordering: ordering, origin: .human,
            createdAt: createdAt, updatedAt: createdAt
        )
    }

    func testSelectsOnlyReviewTasks() {
        let all = [
            task("proposed", column: .proposed, ordering: 1),
            task("review", column: .review, ordering: 1),
            task("running", column: .running, ordering: 1),
            task("done", column: .done, ordering: 1),
        ]
        XCTAssertEqual(BoardTask.pendingReview(in: all).map(\.id), ["review"])
    }

    func testEmptyWhenNothingIsInReview() {
        let all = [task("a", column: .ready, ordering: 1), task("b", column: .done, ordering: 2)]
        XCTAssertTrue(BoardTask.pendingReview(in: all).isEmpty)
    }

    func testOrdersByColumnOrdering() {
        let all = [
            task("third", column: .review, ordering: 30),
            task("first", column: .review, ordering: 10),
            task("second", column: .review, ordering: 20),
        ]
        XCTAssertEqual(BoardTask.pendingReview(in: all).map(\.id), ["first", "second", "third"])
    }

    func testTiedOrderingFallsBackToCreationThenId() {
        let all = [
            task("b", column: .review, ordering: 1, createdAt: 200),
            task("c", column: .review, ordering: 1, createdAt: 300),
            task("a", column: .review, ordering: 1, createdAt: 200),
        ]
        XCTAssertEqual(BoardTask.pendingReview(in: all).map(\.id), ["a", "b", "c"])
    }

    func testMatchesStoreOrderingForTasksMovedIntoReview() throws {
        let fixture = try Fixture.make()
        let first = try fixture.task("first", column: .running)
        let second = try fixture.task("second", column: .running)
        try fixture.tasks.move(second.id, to: .review)
        try fixture.tasks.move(first.id, to: .review)

        let stored = try fixture.tasks.list(projectId: fixture.project.id)
        XCTAssertEqual(BoardTask.pendingReview(in: stored).map(\.title), ["second", "first"])
    }
}
