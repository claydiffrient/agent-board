import Foundation
import XCTest
@testable import AgentBoardCore

final class NoteStoreTests: XCTestCase {
    func testCreateAndReadRoundTripPreservesSectionOrder() throws {
        let f = try Fixture.make()
        let note = try f.notes.create(
            projectId: f.project.id,
            title: "Build constraints",
            sections: [("Toolchain", "Swift 6"), ("Gotchas", "FTS5 is contentless"), ("Links", "SPEC.md")]
        )
        XCTAssertEqual(note.version, 1)
        XCTAssertFalse(note.pinned)

        let (read, sections) = try XCTUnwrap(f.notes.read(note.id))
        XCTAssertEqual(read, note)
        XCTAssertEqual(sections.map(\.heading), ["Toolchain", "Gotchas", "Links"])
        XCTAssertEqual(sections.map(\.body), ["Swift 6", "FTS5 is contentless", "SPEC.md"])
        XCTAssertEqual(sections.map(\.ordering), [1, 2, 3])
    }

    func testReadOfUnknownNoteIsNil() throws {
        let f = try Fixture.make()
        XCTAssertNil(try f.notes.read("nope"))
    }

    func testAppendAndReplaceBumpVersion() throws {
        let f = try Fixture.make()
        let note = try f.notes.create(projectId: f.project.id, title: "N", sections: [("A", "one")])

        let afterAppend = try f.notes.appendSection(noteId: note.id, heading: "B", body: "two")
        XCTAssertEqual(afterAppend.version, 2)
        XCTAssertGreaterThanOrEqual(afterAppend.updatedAt, note.updatedAt)

        let afterReplace = try f.notes.replaceSection(noteId: note.id, heading: "A", body: "one prime")
        XCTAssertEqual(afterReplace.version, 3)

        let (_, sections) = try XCTUnwrap(f.notes.read(note.id))
        XCTAssertEqual(sections.map(\.heading), ["A", "B"])
        XCTAssertEqual(sections.map(\.body), ["one prime", "two"])
    }

    func testReplaceSectionCreatesMissingHeading() throws {
        let f = try Fixture.make()
        let note = try f.notes.create(projectId: f.project.id, title: "N", sections: [])
        try f.notes.replaceSection(noteId: note.id, heading: "New", body: "body")
        let (_, sections) = try XCTUnwrap(f.notes.read(note.id))
        XCTAssertEqual(sections.map(\.heading), ["New"])
    }

    func testVersionMismatchThrowsAndWritesNothing() throws {
        let f = try Fixture.make()
        let note = try f.notes.create(projectId: f.project.id, title: "N", sections: [("A", "one")])
        try f.notes.appendSection(noteId: note.id, heading: "B", body: "two")
        let (before, sectionsBefore) = try XCTUnwrap(f.notes.read(note.id))

        XCTAssertThrowsError(try f.notes.appendSection(noteId: note.id, heading: "C", body: "three", ifVersion: 1)) {
            XCTAssertEqual($0 as? NoteError, .versionConflict(noteId: note.id, expected: 1, current: 2))
        }
        XCTAssertThrowsError(try f.notes.replaceSection(noteId: note.id, heading: "A", body: "clobber", ifVersion: 99)) {
            XCTAssertEqual($0 as? NoteError, .versionConflict(noteId: note.id, expected: 99, current: 2))
        }

        let (after, sectionsAfter) = try XCTUnwrap(f.notes.read(note.id))
        XCTAssertEqual(after, before)
        XCTAssertEqual(sectionsAfter, sectionsBefore)
        XCTAssertEqual(try f.notes.search(projectId: f.project.id, query: "clobber"), [])
    }

    func testMatchingVersionIsAccepted() throws {
        let f = try Fixture.make()
        let note = try f.notes.create(projectId: f.project.id, title: "N", sections: [])
        let bumped = try f.notes.appendSection(noteId: note.id, heading: "A", body: "one", ifVersion: 1)
        XCTAssertEqual(bumped.version, 2)
    }

    func testAppendToUnknownNoteThrows() throws {
        let f = try Fixture.make()
        XCTAssertThrowsError(try f.notes.appendSection(noteId: "ghost", heading: "A", body: "x")) {
            XCTAssertEqual($0 as? NoteError, .noteNotFound("ghost"))
        }
    }

    func testConcurrentAppendsToDifferentHeadingsBothSurvive() throws {
        let f = try Fixture.make()
        let note = try f.notes.create(projectId: f.project.id, title: "Shared", sections: [])

        let workers = 2
        let done = expectation(description: "appends")
        done.expectedFulfillmentCount = workers
        let store = f.notes
        for i in 0..<workers {
            DispatchQueue.global().async {
                try? store.appendSection(noteId: note.id, heading: "worker-\(i)", body: "finding \(i)")
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 10)

        let (final, sections) = try XCTUnwrap(f.notes.read(note.id))
        XCTAssertEqual(final.version, 3)
        XCTAssertEqual(sections.map(\.heading).sorted(), ["worker-0", "worker-1"])
        XCTAssertEqual(try f.notes.search(projectId: f.project.id, query: "finding").map(\.id), [note.id])
    }

    func testAppendToExistingHeadingKeepsBothBodies() throws {
        let f = try Fixture.make()
        let note = try f.notes.create(projectId: f.project.id, title: "N", sections: [("A", "first")])
        try f.notes.appendSection(noteId: note.id, heading: "A", body: "second")

        let (_, sections) = try XCTUnwrap(f.notes.read(note.id))
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].body, "first\n\nsecond")
        XCTAssertEqual(try f.notes.search(projectId: f.project.id, query: "first").map(\.id), [note.id])
        XCTAssertEqual(try f.notes.search(projectId: f.project.id, query: "second").map(\.id), [note.id])
    }

    func testPinToggle() throws {
        let f = try Fixture.make()
        let note = try f.notes.create(projectId: f.project.id, title: "N", sections: [])
        XCTAssertEqual(try f.notes.pinned(projectId: f.project.id), [])

        try f.notes.pin(note.id, true)
        XCTAssertEqual(try f.notes.pinned(projectId: f.project.id).map(\.id), [note.id])
        XCTAssertEqual(try f.notes.get(note.id)?.pinned, true)

        try f.notes.pin(note.id, false)
        XCTAssertEqual(try f.notes.pinned(projectId: f.project.id), [])
    }

    func testAttachDetachAndLookups() throws {
        let f = try Fixture.make()
        let task = try f.task("t")
        let epic = Epic(
            id: Epic.newId(), projectId: f.project.id, title: "E", goal: nil,
            branch: "agentboard/epic-n", state: .planning, createdAt: .nowMillis
        )
        try f.db.writer.write { try epic.insert($0) }
        let note = try f.notes.create(projectId: f.project.id, title: "N", sections: [])
        let other = try f.notes.create(projectId: f.project.id, title: "Other", sections: [])

        try f.notes.attach(noteId: note.id, taskId: task.id)
        try f.notes.attach(noteId: note.id, taskId: task.id)
        try f.notes.attach(noteId: note.id, epicId: epic.id)

        XCTAssertEqual(try f.notes.links(noteId: note.id).count, 2)
        XCTAssertEqual(try f.notes.notes(forTask: task.id).map(\.id), [note.id])
        XCTAssertEqual(try f.notes.notes(forEpic: epic.id).map(\.id), [note.id])
        XCTAssertEqual(try f.notes.notes(forTask: other.id), [])

        try f.notes.detach(noteId: note.id, taskId: task.id)
        XCTAssertEqual(try f.notes.notes(forTask: task.id), [])
        XCTAssertEqual(try f.notes.notes(forEpic: epic.id).map(\.id), [note.id])
    }

    func testSearchFindsByTitleAndSectionBody() throws {
        let f = try Fixture.make()
        let note = try f.notes.create(
            projectId: f.project.id,
            title: "Tokenizer notes",
            sections: [("Pitfall", "the parser rejects unicode escapes")]
        )
        try f.notes.create(projectId: f.project.id, title: "Unrelated", sections: [("X", "nothing here")])

        XCTAssertEqual(try f.notes.search(projectId: f.project.id, query: "tokenizer").map(\.id), [note.id])
        XCTAssertEqual(try f.notes.search(projectId: f.project.id, query: "unicode").map(\.id), [note.id])
        XCTAssertEqual(try f.notes.search(projectId: f.project.id, query: "absent").map(\.id), [])
    }

    func testSearchIsScopedToProject() throws {
        let f = try Fixture.make()
        let otherProject = try f.projects.register(
            name: "Other", repoPath: "/tmp/other-\(UUID().uuidString)", baseBranch: "main",
            worktreeRoot: "/tmp/other-worktrees", memoryDir: nil
        )
        try f.notes.create(projectId: otherProject.id, title: "Elsewhere", sections: [("A", "shared word")])
        let mine = try f.notes.create(projectId: f.project.id, title: "Mine", sections: [("A", "shared word")])

        XCTAssertEqual(try f.notes.search(projectId: f.project.id, query: "shared").map(\.id), [mine.id])
    }

    func testSearchStopsMatchingReplacedText() throws {
        let f = try Fixture.make()
        let note = try f.notes.create(
            projectId: f.project.id, title: "N", sections: [("Pitfall", "beware the leaky abstraction")]
        )
        XCTAssertEqual(try f.notes.search(projectId: f.project.id, query: "leaky").map(\.id), [note.id])

        try f.notes.replaceSection(noteId: note.id, heading: "Pitfall", body: "resolved upstream")
        XCTAssertEqual(try f.notes.search(projectId: f.project.id, query: "leaky"), [])
        XCTAssertEqual(try f.notes.search(projectId: f.project.id, query: "resolved").map(\.id), [note.id])
    }

    func testSearchStopsMatchingDeletedNote() throws {
        let f = try Fixture.make()
        let note = try f.notes.create(
            projectId: f.project.id, title: "Ephemeral", sections: [("A", "transient detail")]
        )
        try f.notes.attach(noteId: note.id, taskId: try f.task("t").id)
        XCTAssertEqual(try f.notes.search(projectId: f.project.id, query: "transient").map(\.id), [note.id])

        try f.notes.delete(note.id)
        XCTAssertNil(try f.notes.read(note.id))
        XCTAssertEqual(try f.notes.search(projectId: f.project.id, query: "transient"), [])
        XCTAssertEqual(try f.notes.search(projectId: f.project.id, query: "Ephemeral"), [])
    }

    func testRebuildIndexDropsEntriesWhoseNoteRowsWereDeletedUnindexed() throws {
        let f = try Fixture.make()
        let old = try f.notes.create(projectId: f.project.id, title: "Idle cap secrets", sections: [("Why", "stale text")])
        try f.db.writer.write { db in
            try db.execute(sql: "DELETE FROM note_section WHERE note_id = ?", arguments: [old.id])
            try db.execute(sql: "DELETE FROM note WHERE id = ?", arguments: [old.id])
        }
        let new = try f.notes.create(projectId: f.project.id, title: "Groceries", sections: [("List", "milk")])
        XCTAssertEqual(try f.notes.search(projectId: f.project.id, query: "stale").map(\.id), [new.id])

        try f.db.writer.write { try NoteStore.rebuildIndex($0) }

        XCTAssertEqual(try f.notes.search(projectId: f.project.id, query: "stale"), [])
        XCTAssertEqual(try f.notes.search(projectId: f.project.id, query: "milk").map(\.id), [new.id])
        try f.notes.delete(new.id)
        XCTAssertEqual(try f.notes.search(projectId: f.project.id, query: "milk"), [])
    }

    func testSearchToleratesFtsSyntaxInQuery() throws {
        let f = try Fixture.make()
        let note = try f.notes.create(projectId: f.project.id, title: "N", sections: [("A", "don't panic")])
        XCTAssertEqual(try f.notes.search(projectId: f.project.id, query: "don't").map(\.id), [note.id])
        XCTAssertEqual(try f.notes.search(projectId: f.project.id, query: "   "), [])
    }

    func testObserveEmitsProjectNotesPinnedFirst() throws {
        let f = try Fixture.make()
        let plain = try f.notes.create(projectId: f.project.id, title: "Plain", sections: [])
        let important = try f.notes.create(projectId: f.project.id, title: "Important", sections: [])
        try f.notes.pin(important.id, true)

        let observed = expectation(description: "observed")
        var ids: [String] = []
        let cancellable = f.notes.observe(projectId: f.project.id).start(
            in: f.db.reader,
            scheduling: .immediate,
            onError: { XCTFail("\($0)") },
            onChange: { notes in
                ids = notes.map(\.id)
                observed.fulfill()
            }
        )
        wait(for: [observed], timeout: 5)
        cancellable.cancel()
        XCTAssertEqual(ids, [important.id, plain.id])
    }
}

final class NoteSectionWriterTests: XCTestCase {
    func testEachSectionRecordsItsLastWriter() throws {
        let f = try Fixture.make()
        let note = try f.notes.create(
            projectId: f.project.id, title: "N", sections: [("A", "one")], writtenBy: "session-1"
        )
        try f.notes.appendSection(noteId: note.id, heading: "B", body: "two", writtenBy: "session-2")
        try f.notes.appendSection(noteId: note.id, heading: "A", body: "more", writtenBy: "session-3")

        let (_, sections) = try XCTUnwrap(f.notes.read(note.id))
        XCTAssertEqual(sections.map(\.heading), ["A", "B"])
        XCTAssertEqual(sections.map(\.writtenBy), ["session-3", "session-2"])
    }

    func testAHumanEditClearsTheAgentWriter() throws {
        let f = try Fixture.make()
        let note = try f.notes.create(
            projectId: f.project.id, title: "N", sections: [("A", "one")], writtenBy: "session-1"
        )
        try f.notes.replaceSection(noteId: note.id, heading: "A", body: "edited by hand", writtenBy: nil)
        let (_, sections) = try XCTUnwrap(f.notes.read(note.id))
        XCTAssertNil(sections[0].writtenBy)
    }

    func testDeleteSectionBumpsVersionAndDropsItFromSearch() throws {
        let f = try Fixture.make()
        let note = try f.notes.create(
            projectId: f.project.id, title: "N", sections: [("Keep", "kept"), ("Drop", "zygomorphic")]
        )
        try f.notes.deleteSection(noteId: note.id, heading: "Drop")

        let (after, sections) = try XCTUnwrap(f.notes.read(note.id))
        XCTAssertEqual(after.version, 2)
        XCTAssertEqual(sections.map(\.heading), ["Keep"])
        XCTAssertEqual(try f.notes.search(projectId: f.project.id, query: "zygomorphic").count, 0)
        XCTAssertEqual(try f.notes.search(projectId: f.project.id, query: "kept").count, 1)
    }
}
