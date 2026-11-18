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

    /// SPEC §15.7: an overruled finding leaves the set a re-review grades, and cannot carry a reopen alone.
    func testAnOverruledFindingIsSettledForTheNextRound() throws {
        let f = try Fixture.make()
        let task = try f.task("write the parser", column: .review)
        try f.sessions.insert(f.session("rev-1", taskId: task.id))
        try f.board.reviewReopen(
            taskId: task.id, sessionId: "rev-1", reviewerName: "Rowan",
            findings: ["Empty input throws.", "Rename Parser to Reader.", "No test covers a trailing comma."]
        )
        try RulingStore(f.db).record(
            .reviewFinding(taskId: task.id, ref: ReviewRound.findingRef(round: 1, finding: 2)),
            question: "Rename Parser to Reader.", questionAt: 1, verdict: .overrule, note: "Parser is the public name."
        )
        try f.tasks.move(task.id, to: .review)
        try f.sessions.insert(f.session("rev-2", taskId: task.id))
        let grades = [1, 3].map { GradedFinding(finding: $0, grade: .fixed, evidence: "Parser.swift:\($0)") }

        let prompt = try XCTUnwrap(ReviewPrompt.recorded(db: f.db, session: XCTUnwrap(f.sessions.get("rev-2"))))
        XCTAssertTrue(prompt.contains("- Finding 2 overruled: Parser is the public name."), prompt)
        XCTAssertThrowsError(try f.board.reviewReopen(
            taskId: task.id, sessionId: "rev-2", reviewerName: "Rowan",
            findings: ["Finding 2 is still not addressed: rename Parser to Reader."], grades: grades
        )) { XCTAssertTrue(($0 as? ReviewReopenRejection)?.reason.contains("overruled") == true, "\($0)") }
        let round = try f.board.recordReviewVerdict(
            taskId: task.id, sessionId: "rev-2", reviewerName: "Rowan", verdict: "Both fixes hold.", grades: grades
        )
        XCTAssertEqual(round.grades.map(\.finding), [1, 3])
    }

    /// SPEC §15.7: with `finding_refs`, a rephrased re-raise of an overruled finding is still refused,
    /// and a reopen that also raises something new goes through.
    func testFindingRefsRefuseARephrasedReRaiseOfAnOverruledFinding() throws {
        let f = try Fixture.make()
        let task = try f.task("write the parser", column: .review)
        try f.sessions.insert(f.session("rev-1", taskId: task.id))
        try f.board.reviewReopen(
            taskId: task.id, sessionId: "rev-1", reviewerName: "Rowan",
            findings: ["Empty input throws.", "Rename Parser to Reader."]
        )
        try RulingStore(f.db).record(
            .reviewFinding(taskId: task.id, ref: ReviewRound.findingRef(round: 1, finding: 2)),
            question: "Rename Parser to Reader.", questionAt: 1, verdict: .overrule, note: "Parser is the public name."
        )
        try f.tasks.move(task.id, to: .review)
        try f.sessions.insert(f.session("rev-2", taskId: task.id))
        let grades = [GradedFinding(finding: 1, grade: .fixed, evidence: "Parser.swift:1")]
        let rephrased = "The type is still called Parser; Reader reads better."

        XCTAssertThrowsError(try f.board.reviewReopen(
            taskId: task.id, sessionId: "rev-2", reviewerName: "Rowan",
            findings: [rephrased], grades: grades, findingRefs: [[2]]
        )) { XCTAssertTrue(($0 as? ReviewReopenRejection)?.reason.contains("overruled") == true, "\($0)") }

        let reopen = try f.board.reviewReopen(
            taskId: task.id, sessionId: "rev-2", reviewerName: "Rowan",
            findings: [rephrased, "Trailing commas are not handled."], grades: grades, findingRefs: [[2], []]
        )
        XCTAssertEqual(reopen.round.number, 2)
    }
}
