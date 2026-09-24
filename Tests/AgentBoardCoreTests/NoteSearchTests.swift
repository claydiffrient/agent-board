import Foundation
import GRDB
import XCTest
@testable import AgentBoardCore

final class NoteSearchTests: XCTestCase {
    func testEveryTermBecomesARequiredQuotedPrefix() {
        XCTAssertEqual(NoteSearch.ftsQuery("idle cap"), "\"idle\"* \"cap\"*")
        XCTAssertEqual(NoteSearch.ftsQuery("  idle\t"), "\"idle\"*")
        XCTAssertEqual(NoteSearch.ftsQuery("say \"hi"), "\"say\"* \"\"\"hi\"*")
    }

    func testTextWithNothingSearchableIsNoQueryRatherThanNoMatch() {
        for text in ["", "   ", "\"", "-", "*", "( )", "\" \""] {
            XCTAssertNil(NoteSearch.ftsQuery(text), text)
        }
    }

    /// Typed as-is, most of these are FTS5 syntax errors, and `NoteStore.search` quietly retries a
    /// query that fails, so whether the rewritten query parses is checked with MATCH itself.
    func testHalfTypedAndInvalidQueriesParseAndStillFindTheNote() throws {
        let f = try Fixture.make()
        let idle = try f.notes.create(projectId: f.project.id, title: "Idle cap watchdog", sections: [])
        try f.notes.create(projectId: f.project.id, title: "Port sweep", sections: [])
        func match(_ query: String) throws -> [Row] {
            try f.db.reader.read { db in
                try Row.fetchAll(db, sql: "SELECT rowid FROM note_fts WHERE note_fts MATCH ?", arguments: [query])
            }
        }

        for raw in ["cap:", "\"idle", "idle AND", "NEAR(idle", "(idle", "idle -"] {
            XCTAssertThrowsError(try match(raw), "\(raw) parses as typed, so it proves nothing here")
        }

        let literalOnly = ["idle AND", "idle OR", "NOT idle", "NEAR(idle", "title:idle"]
        for typed in ["cap:", "\"idle", "idle \"", "(idle", "idle)", "^idle", "idle*", "idle -", "id"] + literalOnly {
            let query = try XCTUnwrap(NoteSearch.ftsQuery(typed), typed)
            XCTAssertNoThrow(try match(query), "\(typed) → \(query)")
            let found = try f.notes.search(projectId: f.project.id, query: query).map(\.id)
            XCTAssertEqual(found, literalOnly.contains(typed) ? [] : [idle.id], "\(typed) → \(query)")
        }
    }

    func testATermMatchesATokenPrefixNotAnySubstring() throws {
        let f = try Fixture.make()
        let idle = try f.notes.create(projectId: f.project.id, title: "Idle cap", sections: [])
        XCTAssertEqual(try search(f, "idl"), [idle.id])
        XCTAssertEqual(try search(f, "ÍDLE"), [idle.id])
        XCTAssertEqual(try search(f, "dle"), [])
    }

    /// `note_fts.body` is every section's heading and text, so a note is found by what it says,
    /// not only by its title.
    func testSectionHeadingsAndTextAreSearched() throws {
        let f = try Fixture.make()
        let note = try f.notes.create(projectId: f.project.id, title: "Plain", sections: [("Watchdog", "kills idle workers")])
        try f.notes.appendSection(noteId: note.id, heading: "Later", body: "timeout measured")
        XCTAssertEqual(try search(f, "watchdog"), [note.id])
        XCTAssertEqual(try search(f, "idle kills"), [note.id])
        XCTAssertEqual(try search(f, "timeout"), [note.id])
        XCTAssertEqual(try search(f, "plain timeout"), [note.id])
        XCTAssertEqual(try search(f, "plain absent"), [])
    }

    private func search(_ f: Fixture, _ typed: String) throws -> [String] {
        try f.notes.search(projectId: f.project.id, query: XCTUnwrap(NoteSearch.ftsQuery(typed))).map(\.id)
    }
}
