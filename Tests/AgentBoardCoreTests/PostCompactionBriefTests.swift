import Foundation
import XCTest
@testable import AgentBoardCore

final class PostCompactionBriefTests: XCTestCase {
    private func seed() throws -> (Fixture, BoardTask, Epic) {
        let f = try Fixture.make()
        let epic = Epic(
            id: BoardId.new(), projectId: f.project.id, title: "Hooks", goal: "Close the hook gaps.",
            branch: "agentboard/epic-hooks", state: .active, createdAt: .nowMillis
        )
        try f.db.writer.write { db in try epic.insert(db) }
        let task = try f.tasks.create(
            projectId: f.project.id, title: "Tell the board when a worker compacts",
            body: "Add PreCompact and SubagentStop.", acceptance: "swift build clean.",
            priority: nil, column: .ready, origin: .human, epicId: epic.id
        )
        return (f, task, epic)
    }

    func testTheBriefCarriesTitleBodyAcceptanceEpicGoalAndNotes() throws {
        let (f, task, epic) = try seed()
        let note = try f.notes.create(
            projectId: f.project.id, title: "Headless UI verification",
            sections: [(heading: "What works", body: "An offscreen NSWindow.")]
        )
        try f.notes.attach(noteId: note.id, taskId: task.id)
        let notes = try f.notes.notesForSpawn(projectId: f.project.id, taskId: task.id, epicId: epic.id)

        let brief = OpeningPrompt.postCompactionBrief(
            task: task, branch: "agentboard/t1", epicGoal: epic.goal, notes: notes
        )

        XCTAssertTrue(brief.contains("Tell the board when a worker compacts"), brief)
        XCTAssertTrue(brief.contains("Add PreCompact and SubagentStop."), brief)
        XCTAssertTrue(brief.contains("swift build clean."), brief)
        XCTAssertTrue(brief.contains("Close the hook gaps."), brief)
        XCTAssertTrue(brief.contains("An offscreen NSWindow."), brief)
        XCTAssertTrue(brief.contains("agentboard/t1"), brief)
    }

    /// The re-brief and the spawn prompt are built from the same sections, so a reworded acceptance
    /// header or note fence in one cannot silently diverge from the other.
    func testEverySectionOfTheBriefAppearsVerbatimInTheSpawnPrompt() throws {
        let (f, task, epic) = try seed()
        let note = try f.notes.create(
            projectId: f.project.id, title: "Epic branches",
            sections: [(heading: "The rule", body: "A sibling's work is not in your worktree.")]
        )
        try f.notes.attach(noteId: note.id, epicId: epic.id)
        let notes = try f.notes.notesForSpawn(projectId: f.project.id, taskId: task.id, epicId: epic.id)

        let spawn = OpeningPrompt.compose(
            task: task, branch: "agentboard/t1", attempt: 1, epicGoal: epic.goal, notes: notes
        )
        var sections = OpeningPrompt.taskSections(task: task, epicGoal: epic.goal)
        sections.append(try XCTUnwrap(OpeningPrompt.renderNotes(notes)))

        XCTAssertEqual(sections.count, 5)
        for section in sections {
            XCTAssertTrue(spawn.contains(section), "spawn prompt is missing:\n\(section)")
            XCTAssertTrue(
                OpeningPrompt.postCompactionBrief(
                    task: task, branch: "agentboard/t1", epicGoal: epic.goal, notes: notes
                ).contains(section),
                "re-brief is missing:\n\(section)"
            )
        }
    }

    func testTheBriefSaysATurnWithoutAToolCallStopsTheTask() throws {
        let (_, task, epic) = try seed()
        let brief = OpeningPrompt.postCompactionBrief(task: task, branch: "agentboard/t1", epicGoal: epic.goal)
        XCTAssertTrue(brief.contains("a message with no tool call in it ends your turn"), brief)
    }

    func testNotesAreDroppedRatherThanOverflowingTheInjectionCap() throws {
        let (f, task, epic) = try seed()
        let note = try f.notes.create(
            projectId: f.project.id, title: "Huge",
            sections: [(heading: "Body", body: String(repeating: "x", count: 20_000))]
        )
        try f.notes.attach(noteId: note.id, taskId: task.id)
        let notes = try f.notes.notesForSpawn(projectId: f.project.id, taskId: task.id, epicId: epic.id)

        let brief = OpeningPrompt.postCompactionBrief(
            task: task, branch: "agentboard/t1", epicGoal: epic.goal, notes: notes
        )

        XCTAssertLessThanOrEqual(brief.count, OpeningPrompt.briefCharacterBudget)
        XCTAssertFalse(brief.contains(String(repeating: "x", count: 100)))
        XCTAssertTrue(brief.contains("swift build clean."), brief)
    }

    /// A long task used to fill the budget before the thread was considered, dropping it whole.
    func testALongTaskStillLeavesRoomForTheNewestHumanComment() throws {
        let (f, _, epic) = try seed()
        let body = String(repeating: "Parse the input. ", count: 313)
        let task = try f.tasks.create(
            projectId: f.project.id, title: "A long task", body: body, acceptance: "swift build clean.",
            priority: nil, column: .ready, origin: .human, epicId: epic.id
        )
        var thread = (1...12).map { n in
            TaskComment(
                id: Int64(n), taskId: task.id, projectId: f.project.id,
                author: CommentAuthor(kind: .worker, name: "Worker"),
                body: "Finding \(n). " + String(repeating: "y", count: 400), createdAt: Int64(n) * 1000
            )
        }
        thread.append(TaskComment(
            id: 13, taskId: task.id, projectId: f.project.id, author: .human,
            body: "Stop: the migration must stay reversible.", createdAt: 13_000
        ))

        let brief = OpeningPrompt.postCompactionBrief(
            task: task, branch: "agentboard/t1", epicGoal: epic.goal, comments: thread
        )

        XCTAssertGreaterThanOrEqual(body.count, 5_000)
        XCTAssertLessThanOrEqual(brief.count, OpeningPrompt.briefCharacterBudget)
        XCTAssertTrue(brief.contains(body))
        XCTAssertTrue(brief.contains("swift build clean."))
        XCTAssertTrue(brief.contains("Stop: the migration must stay reversible."), String(brief.suffix(1_500)))
        XCTAssertTrue(brief.contains("older comments are left out"))
    }
}
