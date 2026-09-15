import AgentBoardBridge
import AgentBoardCore
import AgentBoardServer
import Foundation
import XCTest

final class NoteResourceTests: XCTestCase {
    private var f: BridgeFixture!
    private var resources: NoteResourceHandler!
    private var worker: TokenIdentity!

    override func setUpWithError() throws {
        f = try BridgeFixture.make()
        resources = NoteResourceHandler(db: f.db)
        let task = try f.task("t", column: .running)
        try f.session("s1", taskId: task.id)
        worker = f.workerIdentity(sessionId: "s1", taskId: task.id)
    }

    private func list() async throws -> [ResourceDescriptor] {
        try await resources.resources(for: worker)
    }

    private func listedFirst(file: StaticString = #filePath, line: UInt = #line) async throws -> ResourceDescriptor {
        let listed = try await list()
        return try XCTUnwrap(listed.first, "nothing listed", file: file, line: line)
    }

    private func uri(_ note: Note) -> String {
        NoteResourceHandler.uri(projectId: note.projectId, noteId: note.id)
    }

    // MARK: Listing

    func testEveryNoteInTheProjectIsListedOnceUnderItsOwnUriAndTitle() async throws {
        let build = try f.note("Build gotchas", sections: [("The trap", "merge then compile")])
        let spawn = try f.note("Spawn traps", sections: [("FORCE_COLOR", "unset it")])
        let empty = try f.note("Nothing learned yet")

        let listed = try await list()
        XCTAssertEqual(listed.count, 3)
        XCTAssertEqual(Set(listed.map(\.uri)), Set([build, spawn, empty].map(uri)))
        XCTAssertEqual(Set(listed.map(\.name)), ["Build gotchas", "Spawn traps", "Nothing learned yet"])
        XCTAssertEqual(Set(listed.map(\.mimeType)), ["application/json"])
    }

    func testANoteInAnotherProjectIsNotListed() async throws {
        let mine = try f.note("Mine")
        let other = try f.note("Theirs", in: try f.otherProject().id)

        let listed = try await list()
        XCTAssertEqual(listed.map(\.uri), [uri(mine)])
        XCTAssertFalse(listed.contains { $0.uri == uri(other) }, "a note from another project leaked into the listing")
        XCTAssertFalse(listed.contains { $0.name == "Theirs" })
    }

    func testAUriSurvivesEditingTheNote() async throws {
        let note = try f.note("Build gotchas", sections: [("The trap", "merge then compile")])
        let before = try await listedFirst()

        _ = try await f.call(
            "append_section",
            ["note_id": .string(note.id), "heading": .string("Also"), "body": .string("check the stub")],
            as: worker
        )

        let after = try await listedFirst()
        XCTAssertEqual(after.uri, before.uri)
        XCTAssertEqual(try f.notes.get(note.id)?.version, 2, "the note really did change under the stable uri")
    }

    func testCreatingANoteMakesItAppearInASubsequentList() async throws {
        let before = try await list()
        XCTAssertEqual(before.count, 0)

        let created = try await f.callJSON(
            "create_note",
            [
                "title": .string("Headless UI verification"),
                "sections": .array([.object(["heading": .string("What works"), "body": .string("offscreen NSWindow")])]),
            ],
            as: worker
        )
        let id = try XCTUnwrap(created["id"]?.stringValue)

        let listed = try await list()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].uri, NoteResourceHandler.uri(projectId: f.project.id, noteId: id))
        XCTAssertEqual(listed[0].name, "Headless UI verification")
    }

    func testTheDescriptionNamesTheSectionsAndWhetherTheNoteIsPinned() async throws {
        let note = try f.note(
            "Build gotchas",
            sections: [("The trap", "a"), ("What to do", "b"), ("Files that collide", "c")]
        )
        let unpinned = try await listedFirst()
        XCTAssertTrue(unpinned.description.contains("3 sections: The trap · What to do · Files that collide"), unpinned.description)
        XCTAssertFalse(unpinned.description.contains("Pinned"))
        XCTAssertTrue(unpinned.description.contains("Version 1"), unpinned.description)

        try f.notes.pin(note.id, true)
        let pinned = try await listedFirst()
        XCTAssertTrue(pinned.description.hasPrefix("Pinned into every agent on this project."), pinned.description)
    }

    func testASectionlessNoteSaysSoRatherThanListingNothing() async throws {
        _ = try f.note("Nothing learned yet")
        let listed = try await listedFirst()
        XCTAssertTrue(listed.description.contains("No sections yet."), listed.description)
    }

    // MARK: Reading

    func testReadingByUriReturnsExactlyWhatReadNoteReturns() async throws {
        let note = try f.note(
            "Build gotchas",
            sections: [("The trap", "merge then compile"), ("What to do", "add the missing method")]
        )

        let contents = try await resources.read(uri(note), identity: worker)
        let viaTool = try await f.call("read_note", ["id": .string(note.id)], as: worker)

        XCTAssertEqual(contents.count, 1)
        XCTAssertEqual(contents[0].uri, uri(note))
        XCTAssertEqual(contents[0].mimeType, "application/json")
        XCTAssertEqual(contents[0].text, viaTool.text)
        XCTAssertTrue(contents[0].text.contains("merge then compile"))
    }

    func testAnUnknownNoteIdIsRefusedRatherThanReturningEmptyContent() async throws {
        let missing = NoteResourceHandler.uri(projectId: f.project.id, noteId: "00000000-dead-beef-0000-000000000000")
        await assertRefused(missing, containing: "No note")
    }

    func testANoteInAnotherProjectCannotBeReadEvenWithItsRealUri() async throws {
        let other = try f.note("Theirs", sections: [("Secret", "do not leak")], in: try f.otherProject().id)
        await assertRefused(uri(other))
        await assertRefused(NoteResourceHandler.uri(projectId: f.project.id, noteId: other.id), containing: "No note")
    }

    func testMalformedUrisAreRefused() async throws {
        let note = try f.note("Build gotchas")
        for bad in [
            "",
            "not a uri at all",
            note.id,
            "file:///etc/passwd",
            "https://\(f.project.id)/\(note.id)",
            "note://\(f.project.id)",
            "note://\(f.project.id)/",
            "note://\(f.project.id)/\(note.id)/sections",
            "note:///\(note.id)",
        ] {
            await assertRefused(bad)
        }
    }

    func testTheRefusalTellsTheAgentWhatAUriLooksLikeAndWhereToGetOne() async {
        do {
            _ = try await resources.read("note://wrong-project/whatever", identity: worker)
            XCTFail("expected a refusal")
        } catch let error as ResourceError {
            XCTAssertEqual(error.uri, "note://wrong-project/whatever")
            XCTAssertTrue(error.message.contains("note://\(f.project.id)/<note-id>"), error.message)
            XCTAssertTrue(error.message.contains("resources/list"), error.message)
        } catch {
            XCTFail("expected ResourceError, got \(error)")
        }
    }

    private func assertRefused(
        _ uri: String,
        containing fragment: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            let contents = try await resources.read(uri, identity: worker)
            XCTFail("\"\(uri)\" returned \(contents.count) contents instead of being refused", file: file, line: line)
        } catch let error as ResourceError {
            XCTAssertEqual(error.uri, uri, file: file, line: line)
            if let fragment {
                XCTAssertTrue(error.message.contains(fragment), "\"\(error.message)\" lacks \"\(fragment)\"", file: file, line: line)
            }
        } catch {
            XCTFail("expected ResourceError for \"\(uri)\", got \(error)", file: file, line: line)
        }
    }
}
