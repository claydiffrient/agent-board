import Foundation
import XCTest
@testable import AgentBoardCore

/// SPEC §5.1: a re-review starts from the previous round's findings and what changed since it.
final class ReviewRoundTests: XCTestCase {
    func testASecondRoundReviewerIsGivenTheFirstRoundsFindingsAndTheSinceLastReviewRange() throws {
        let f = try Fixture.make()
        let task = try f.task("write the parser", column: .review)
        var first = f.session("rev-1", taskId: task.id)
        first.reviewHead = "1111aaaa"
        try f.sessions.insert(first)
        try f.board.reviewReopen(
            taskId: task.id, sessionId: "rev-1", reviewerName: "Rowan",
            findings: ["The empty input case throws; see Parser.swift:41.", "No test covers a trailing comma."]
        )
        try f.tasks.move(task.id, to: .review)
        var second = f.session("rev-2", taskId: task.id)
        second.reviewHead = "2222bbbb"
        try f.sessions.insert(second)

        let prompt = try XCTUnwrap(ReviewPrompt.recorded(db: f.db, session: second))

        XCTAssertTrue(prompt.contains("The empty input case throws; see Parser.swift:41."), prompt)
        XCTAssertTrue(prompt.contains("No test covers a trailing comma."), prompt)
        XCTAssertTrue(prompt.contains("`git diff 1111aaaa..HEAD`"), prompt)
        XCTAssertTrue(prompt.contains("`git diff main...HEAD`"), prompt)
    }
}
