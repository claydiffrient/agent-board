import AgentBoardBridge
import AgentBoardCore
import AgentBoardServer
import Foundation
import XCTest

/// The spawn prompt tells a worker to fetch an indexed note by its uri. That promise is only
/// worth making if the uris the index prints are the ones the resource handler accepts.
final class SpawnNoteIndexTests: XCTestCase {
    private var f: BridgeFixture!
    private var resources: NoteResourceHandler!
    private var task: BoardTask!
    private var worker: TokenIdentity!

    override func setUpWithError() throws {
        f = try BridgeFixture.make()
        resources = NoteResourceHandler(db: f.db)
        task = try f.task("Work", column: .running)
        try f.session("s1", taskId: task.id)
        worker = f.workerIdentity(sessionId: "s1", taskId: task.id)
    }

    private func index() throws -> [NoteIndexEntry] {
        try f.notes.notesForSpawn(projectId: f.project.id, taskId: task.id, epicId: task.epicId).index
    }

    func testEveryIndexedUriResolvesThroughResourcesRead() async throws {
        let pinned = try f.note("Pinned advice", sections: [("Rule", "never force-push")])
        try f.notes.pin(pinned.id, true)
        let loose = try f.note("Loose note", sections: [("A", "alpha"), ("B", "beta")])
        let empty = try f.note("Nothing learned yet")

        let entries = try index()
        XCTAssertEqual(Set(entries.map(\.id)), Set([pinned.id, loose.id, empty.id]))

        for entry in entries {
            let contents = try await resources.read(entry.uri, identity: worker)
            XCTAssertEqual(contents.count, 1, "no contents for \(entry.title)")
            XCTAssertEqual(contents[0].uri, entry.uri)
            XCTAssertTrue(contents[0].text.contains(entry.title), "\(entry.uri) did not return \(entry.title)")
        }

        let body = try await resources.read(try XCTUnwrap(entries.first { $0.id == loose.id }).uri, identity: worker)
        XCTAssertTrue(body[0].text.contains("alpha"), "the fetched note came back without the body the prompt withheld")
        XCTAssertTrue(body[0].text.contains("beta"))
    }

    func testTheIndexAndTheResourceListingAgreeOnEveryUriTheWorkerIsNotGivenInFull() async throws {
        let attached = try f.note("Attached", sections: [("H", "injected in full")])
        try f.notes.attach(noteId: attached.id, taskId: task.id)
        let pinned = try f.note("Pinned", sections: [("H", "indexed")])
        try f.notes.pin(pinned.id, true)

        let listed = try await resources.resources(for: worker)
        let indexed = Set(try index().map(\.uri))
        XCTAssertEqual(indexed, Set(listed.map(\.uri)).subtracting([NoteResourceURI.uri(projectId: f.project.id, noteId: attached.id)]))
        XCTAssertFalse(indexed.contains(NoteResourceURI.uri(projectId: f.project.id, noteId: attached.id)))
    }

    func testANoteFromAnotherProjectIsNeitherIndexedNorReadable() async throws {
        let foreign = try f.note("Theirs", sections: [("H", "secret")], in: try f.otherProject().id)
        XCTAssertTrue(try index().isEmpty)

        let uri = NoteResourceURI.uri(projectId: foreign.projectId, noteId: foreign.id)
        do {
            _ = try await resources.read(uri, identity: worker)
            XCTFail("a foreign note was readable at \(uri)")
        } catch let error as ResourceError {
            XCTAssertEqual(error.uri, uri)
        }
    }
}
