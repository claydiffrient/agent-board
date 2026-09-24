import XCTest
@testable import AgentBoardCore

/// SPEC §3.1 step 6: the inlined thread keeps the newest comments inside its budget, says how many
/// older ones it left out, and cuts an oversize newest comment short rather than dropping it.
final class CommentPromptTests: XCTestCase {
    private func comment(_ n: Int, body: String) -> TaskComment {
        TaskComment(
            id: Int64(n), taskId: "t", projectId: "p",
            author: CommentAuthor(kind: .worker, name: "Worker \(n)"), body: body, createdAt: Int64(n) * 1000
        )
    }

    func testThreadKeepsTheNewestInsideTheBudgetAndSaysWhatItLeftOut() throws {
        let thread = (1...40).map { comment($0, body: "Comment \($0). " + String(repeating: "x", count: 480)) }
        let section = try XCTUnwrap(CommentPrompt.section(thread, fenceId: "f"))

        XCTAssertLessThan(section.count, CommentPrompt.characterBudget + 1_000)
        XCTAssertTrue(section.contains("Comment 40."))
        XCTAssertFalse(section.contains("Comment 1. "))
        let kept = section.components(separatedBy: "\(CommentPrompt.closeMarker) id=f>>>").count - 1
        XCTAssertTrue(section.contains("\(40 - kept) older comments are left out"), section)
        XCTAssertTrue(section.contains("`get_my_task` returns the whole thread"))

        let huge = try XCTUnwrap(CommentPrompt.section(
            [comment(1, body: "Old."), comment(2, body: String(repeating: "y", count: TaskComment.maxBodyLength))],
            fenceId: "f"
        ))
        XCTAssertLessThan(huge.count, CommentPrompt.characterBudget + 1_000)
        XCTAssertTrue(huge.contains("cut short here; `get_my_task` returns the whole comment"))
        XCTAssertTrue(huge.contains("1 older comment is left out"))
        XCTAssertTrue(huge.hasSuffix("\(CommentPrompt.closeMarker) id=f>>>"))
    }
}
