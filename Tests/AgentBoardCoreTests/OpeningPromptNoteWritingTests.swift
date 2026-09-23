import Foundation
import XCTest
@testable import AgentBoardCore

/// D13 is only half-built if notes flow in and nothing flows back: the store, the tools and the
/// injection all worked for forty sessions and produced zero notes, because no prompt ever asked.
final class OpeningPromptNoteWritingTests: XCTestCase {
    private func task(_ f: Fixture) throws -> BoardTask {
        try f.tasks.create(
            projectId: f.project.id, title: "Work", body: "Do the thing.", acceptance: "It works.",
            priority: nil, column: .ready, origin: .human, epicId: nil
        )
    }

    private func plainPrompt() throws -> String {
        let f = try Fixture.make()
        return OpeningPrompt.compose(task: try task(f), branch: "agentboard/x", attempt: 1)
    }

    private func index(_ needle: String, in text: String) throws -> String.Index {
        try XCTUnwrap(text.range(of: needle), "missing from the prompt: \(needle)").lowerBound
    }

    func testTheClosingProtocolAsksForADurableFinding() throws {
        let text = try plainPrompt()
        XCTAssertTrue(text.contains("Write down one durable finding as a note"))
        XCTAssertTrue(text.contains("a later worker on this project would otherwise have to rediscover"))
        XCTAssertTrue(text.contains("It is not a summary of what you built"))
    }

    func testTheNoteStepSitsInWhenYouAreDoneBeforeReportComplete() throws {
        let text = try plainPrompt()
        let done = try index("## When you are done", in: text)
        let note = try index("Write down one durable finding as a note", in: text)
        let reportComplete = try index("Call `report_complete(", in: text)
        XCTAssertTrue(done < note)
        XCTAssertTrue(note < reportComplete)
    }

    func testTheClosingProtocolSaysToSearchBeforeWritingAndToAppendRatherThanDuplicate() throws {
        let text = try plainPrompt()
        let note = try index("Write down one durable finding as a note", in: text)
        let search = try index("Search before you write", in: text)
        let append = try index("add to it with `append_section`", in: text)
        let create = try index("Call `create_note` only when", in: text)
        XCTAssertTrue(note < search)
        XCTAssertTrue(search < append)
        XCTAssertTrue(append < create)
        XCTAssertTrue(text.contains("`read_note`"))
        XCTAssertTrue(text.contains("splits the answer"))
    }

    func testHowToWorkPointsAtSearchNotesTooNotOnlyTheClosingProtocol() throws {
        let text = try plainPrompt()
        let howToWork = try index("## How to work", in: text)
        let earlySearch = try index("Call `search_notes` when something surprises you", in: text)
        let done = try index("## When you are done", in: text)
        XCTAssertTrue(howToWork < earlySearch)
        XCTAssertTrue(earlySearch < done)
    }

    func testTheCommitAndPushRulesSurviveTheInsertedStep() throws {
        let text = try plainPrompt()
        let commit = try index("Commit on the current branch", in: text)
        let note = try index("Write down one durable finding as a note", in: text)
        let push = try index("Do not push. Do not open a PR.", in: text)
        let reportComplete = try index("Call `report_complete(", in: text)
        XCTAssertTrue(commit < note)
        XCTAssertTrue(note < push)
        XCTAssertTrue(push < reportComplete)
        XCTAssertTrue(text.contains("1. Commit on the current branch"))
        XCTAssertTrue(text.contains("3. Do not push."))
        XCTAssertTrue(text.contains("4. Call `report_complete("))
    }

    func testTheTurnEndingSectionNamesTheEarlyStopsAndTheStopsWanted() throws {
        let text = try plainPrompt()
        let section = try index("## How your turns end", in: text)
        XCTAssertTrue(try index("Call `report_complete(", in: text) < section)
        XCTAssertTrue(text.hasSuffix(OpeningPrompt.turnEnding))
        XCTAssertTrue(text.contains("closes by announcing the next step, with no tool call"))
        XCTAssertTrue(text.contains("put them in the same message as your next tool call"))
        XCTAssertTrue(text.contains("after `report_blocked` when nothing left in the task can move without a human"))
        XCTAssertTrue(text.contains("when Agent Board sends you a wind-down order"))
        XCTAssertTrue(text.contains("This does not override the need for confirmation on risky or destructive actions."))
        XCTAssertTrue(OpeningPrompt.workingProtocol(branch: "agentboard/x").hasSuffix(OpeningPrompt.turnEnding))
        XCTAssertFalse(OpeningPrompt.turnEnding.hasPrefix(" "), "the static let's block indented every line")
    }

    func testEverySectionStillAppearsInOrderWithTheNoteInstructionAdded() throws {
        let f = try Fixture.make()
        let epic = Epic(
            id: BoardId.new(), projectId: f.project.id, title: "E", goal: nil,
            branch: "agentboard/epic-1", state: .active, createdAt: .nowMillis
        )
        try f.db.writer.write { db in try epic.insert(db) }
        let task = try f.tasks.create(
            projectId: f.project.id, title: "Work", body: "Do the thing.", acceptance: "It works.",
            priority: nil, column: .ready, origin: .human, epicId: epic.id
        )
        let note = try f.notes.create(
            projectId: f.project.id, title: "House rules", sections: [("Commits", "Imperative mood.")]
        )
        try f.notes.attach(noteId: note.id, taskId: task.id)
        let injected = try f.notes.notesForSpawn(projectId: f.project.id, taskId: task.id, epicId: epic.id)

        let text = OpeningPrompt.compose(
            task: task, branch: "agentboard/x", attempt: 2,
            epicGoal: "Make notes get written.", notes: injected,
            verification: VerificationCommands(build: "swift build", test: "swift test")
        )

        let expected = [
            "# Task: Work",
            "## Acceptance criteria",
            "## Epic goal",
            "## Attempt 2",
            "## Verification",
            "## Project notes",
            "## How to work",
            "## When you are done",
            "## How your turns end",
        ]
        var cursor = text.startIndex
        for heading in expected {
            let range = try XCTUnwrap(text.range(of: heading, range: cursor..<text.endIndex), "out of order or missing: \(heading)")
            cursor = range.upperBound
        }
        XCTAssertTrue(text.contains("Do the thing."))
        XCTAssertTrue(text.contains("It works."))
        XCTAssertTrue(text.contains("Make notes get written."))
        XCTAssertTrue(text.contains("Imperative mood."))
        XCTAssertTrue(text.contains("swift build"))
    }
}
