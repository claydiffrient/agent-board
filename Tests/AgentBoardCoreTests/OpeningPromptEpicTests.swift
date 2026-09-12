import Foundation
import XCTest
@testable import AgentBoardCore

final class OpeningPromptEpicTests: XCTestCase {
    private func task(_ fixture: Fixture, epicId: String?) throws -> BoardTask {
        try fixture.tasks.create(
            projectId: fixture.project.id, title: "Work", body: "Do the thing.", acceptance: "It works.",
            priority: nil, column: .ready, origin: .human, epicId: epicId
        )
    }

    /// §3.1 step 6 orders the prompt title, body, acceptance criteria, epic goal, then notes.
    func testEpicGoalSitsBetweenAcceptanceCriteriaAndTheNotes() throws {
        let f = try Fixture.make()
        let note = try f.notes.create(
            projectId: f.project.id, title: "House rules", sections: [("Commits", "Imperative mood.")]
        )
        try f.notes.pin(note.id, true)
        let task = try task(f, epicId: nil)
        let notes = try f.notes.notesForSpawn(projectId: f.project.id, taskId: task.id, epicId: nil)

        let text = OpeningPrompt.compose(
            task: task, branch: "agentboard/x", attempt: 1,
            epicGoal: "Merge epic branches unattended.", notes: notes
        )

        let acceptance = try XCTUnwrap(text.range(of: "## Acceptance criteria"))
        let goal = try XCTUnwrap(text.range(of: "## Epic goal"))
        let projectNotes = try XCTUnwrap(text.range(of: "## Project notes"))
        XCTAssertTrue(acceptance.upperBound < goal.lowerBound)
        XCTAssertTrue(goal.upperBound < projectNotes.lowerBound)
        XCTAssertTrue(text.contains("Merge epic branches unattended."))
    }

    func testAnEpicWithNoGoalAddsNoSection() throws {
        let f = try Fixture.make()
        let text = OpeningPrompt.compose(
            task: try task(f, epicId: nil), branch: "agentboard/x", attempt: 1, epicGoal: nil
        )
        XCTAssertFalse(text.contains("## Epic goal"))
    }

    func testABlankGoalAddsNoSection() throws {
        let f = try Fixture.make()
        let text = OpeningPrompt.compose(
            task: try task(f, epicId: nil), branch: "agentboard/x", attempt: 1, epicGoal: "  \n "
        )
        XCTAssertFalse(text.contains("## Epic goal"))
    }
}
