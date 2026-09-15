import XCTest
@testable import AgentBoardCore

final class CommitAttributionTests: XCTestCase {
    private let taskId = "64df6cb7-bd17-4d45-b2db-0f8c13a7f95e"

    func testTheTrailerIsSeparatedFromTheSubjectByABlankLine() {
        let message = CommitAttribution.message("Attribute every commit", taskId: taskId)
        XCTAssertEqual(message, "Attribute every commit\n\nAgent-Board-Task: \(taskId)")
    }

    func testTheTrailerJoinsAnExistingTrailerParagraphRatherThanStartingANewOne() {
        let message = CommitAttribution.message(
            "Attribute every commit\n\nA body paragraph.\n\nCo-authored-by: Someone <s@example.com>",
            taskId: taskId
        )
        XCTAssertEqual(
            message,
            "Attribute every commit\n\nA body paragraph.\n\nCo-authored-by: Someone <s@example.com>"
                + "\nAgent-Board-Task: \(taskId)"
        )
    }

    /// The tool may be called twice on one message; a doubled trailer is two values for one key.
    func testAMessageThatAlreadyCarriesTheTrailerIsUnchanged() {
        let once = CommitAttribution.message("Attribute every commit", taskId: taskId)
        XCTAssertEqual(CommitAttribution.message(once, taskId: taskId), once)
    }

    func testABodyParagraphIsNotMistakenForTrailers() {
        let message = CommitAttribution.message("Subject\n\nA sentence that ends the message.", taskId: taskId)
        XCTAssertEqual(message, "Subject\n\nA sentence that ends the message.\n\nAgent-Board-Task: \(taskId)")
    }

    func testAnEmptyMessageStillGetsTheTrailer() {
        XCTAssertEqual(CommitAttribution.message("   \n", taskId: taskId), "Agent-Board-Task: \(taskId)")
    }

    func testTaskIdReadsBackFromATrailerValue() {
        XCTAssertEqual(CommitAttribution.taskId(trailerValue: " \(taskId) \n"), taskId)
        XCTAssertNil(CommitAttribution.taskId(trailerValue: "   "))
    }
}

final class CommitScopeTests: XCTestCase {
    private func lock(_ path: String, _ sessionId: String) -> FileLock {
        FileLock(projectId: "p", path: path, sessionId: sessionId)
    }

    func testOnlyThisSessionsClaimsAreCommittable() {
        let paths = CommitScope.paths(
            [lock("b.swift", "mine"), lock("sibling.swift", "theirs"), lock("a.swift", "mine")],
            sessionId: "mine"
        )
        XCTAssertEqual(paths, ["a.swift", "b.swift"])
    }

    func testASessionThatHasClaimedNothingGetsNoPaths() {
        XCTAssertEqual(CommitScope.paths([lock("a.swift", "theirs")], sessionId: "mine"), [])
    }
}
