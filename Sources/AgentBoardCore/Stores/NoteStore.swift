import Foundation
import GRDB

public enum NoteError: Error, Equatable, Sendable {
    case noteNotFound(String)
    case versionConflict(noteId: String, expected: Int64, current: Int64)
}

public struct NoteStore: Sendable {
    let db: AppDatabase

    public init(_ db: AppDatabase) {
        self.db = db
    }

    @discardableResult
    public func create(
        projectId: String,
        title: String,
        sections: [(heading: String, body: String)],
        writtenBy: String? = nil
    ) throws -> Note {
        try db.writer.write { db in
            let note = Note(
                id: Note.newId(), projectId: projectId, title: title,
                pinned: false, version: 1, updatedAt: .nowMillis
            )
            try note.insert(db)
            var ordering = 1.0
            for section in sections {
                try NoteSection(
                    noteId: note.id, heading: section.heading, body: section.body,
                    ordering: ordering, writtenBy: writtenBy
                ).insert(db)
                ordering += 1
            }
            try index(db, noteId: note.id)
            return note
        }
    }

    public func get(_ id: String) throws -> Note? {
        try db.reader.read { db in try Note.fetchOne(db, key: id) }
    }

    public func read(_ id: String) throws -> (Note, [NoteSection])? {
        try db.reader.read { db in
            guard let note = try Note.fetchOne(db, key: id) else { return nil }
            return (note, try sections(db, noteId: id))
        }
    }

    public func list(projectId: String) throws -> [Note] {
        try db.reader.read { db in try Self.list(db, projectId: projectId) }
    }

    static func list(_ db: Database, projectId: String) throws -> [Note] {
        try Note.fetchAll(
            db,
            sql: "SELECT * FROM note WHERE project_id = ? ORDER BY pinned DESC, updated_at DESC, title",
            arguments: [projectId]
        )
    }

    public func pinned(projectId: String) throws -> [Note] {
        try db.reader.read { db in
            try Note.fetchAll(
                db,
                sql: "SELECT * FROM note WHERE project_id = ? AND pinned = 1 ORDER BY updated_at DESC, title",
                arguments: [projectId]
            )
        }
    }

    /// Appends to the note's sections. A heading that already exists is *not* overwritten:
    /// `body` is appended to the existing section, separated by a blank line. Losing a
    /// concurrent worker's text is the one failure mode sectioned notes exist to prevent.
    @discardableResult
    public func appendSection(
        noteId: String,
        heading: String,
        body: String,
        ifVersion: Int64? = nil,
        writtenBy: String? = nil
    ) throws -> Note {
        try db.writer.write { db in
            let note = try checkedNote(db, noteId, ifVersion)
            try unindex(db, noteId: noteId)
            if let existing = try NoteSection.fetchOne(db, key: ["note_id": noteId, "heading": heading]) {
                try db.execute(
                    sql: "UPDATE note_section SET body = ?, written_by = ? WHERE note_id = ? AND heading = ?",
                    arguments: [existing.body + "\n\n" + body, writtenBy, noteId, heading]
                )
            } else {
                try NoteSection(
                    noteId: noteId, heading: heading, body: body,
                    ordering: try endOrdering(db, noteId: noteId), writtenBy: writtenBy
                ).insert(db)
            }
            return try bumpVersion(db, note)
        }
    }

    /// Replaces the body of `heading` outright, creating the section if it does not exist yet.
    @discardableResult
    public func replaceSection(
        noteId: String,
        heading: String,
        body: String,
        ifVersion: Int64? = nil,
        writtenBy: String? = nil
    ) throws -> Note {
        try db.writer.write { db in
            let note = try checkedNote(db, noteId, ifVersion)
            try unindex(db, noteId: noteId)
            if try NoteSection.fetchOne(db, key: ["note_id": noteId, "heading": heading]) != nil {
                try db.execute(
                    sql: "UPDATE note_section SET body = ?, written_by = ? WHERE note_id = ? AND heading = ?",
                    arguments: [body, writtenBy, noteId, heading]
                )
            } else {
                try NoteSection(
                    noteId: noteId, heading: heading, body: body,
                    ordering: try endOrdering(db, noteId: noteId), writtenBy: writtenBy
                ).insert(db)
            }
            return try bumpVersion(db, note)
        }
    }

    public func pin(_ id: String, _ pinned: Bool) throws {
        try db.writer.write { db in
            try db.execute(
                sql: "UPDATE note SET pinned = ? WHERE id = ?",
                arguments: [pinned, id]
            )
        }
    }

    public func deleteSection(noteId: String, heading: String) throws {
        try db.writer.write { db in
            guard let note = try Note.fetchOne(db, key: noteId) else { throw NoteError.noteNotFound(noteId) }
            try unindex(db, noteId: noteId)
            try db.execute(
                sql: "DELETE FROM note_section WHERE note_id = ? AND heading = ?",
                arguments: [noteId, heading]
            )
            _ = try bumpVersion(db, note)
        }
    }

    public func delete(_ id: String) throws {
        try db.writer.write { db in
            try unindex(db, noteId: id)
            try db.execute(sql: "DELETE FROM note_link WHERE note_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM note_section WHERE note_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM note WHERE id = ?", arguments: [id])
        }
    }

    public func attach(noteId: String, taskId: String? = nil, epicId: String? = nil) throws {
        try db.writer.write { db in
            let existing = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM note_link WHERE note_id = ? AND task_id IS ? AND epic_id IS ?",
                arguments: [noteId, taskId, epicId]
            ) ?? 0
            guard existing == 0 else { return }
            try NoteLink(noteId: noteId, taskId: taskId, epicId: epicId).insert(db)
        }
    }

    public func detach(noteId: String, taskId: String? = nil, epicId: String? = nil) throws {
        try db.writer.write { db in
            try db.execute(
                sql: "DELETE FROM note_link WHERE note_id = ? AND task_id IS ? AND epic_id IS ?",
                arguments: [noteId, taskId, epicId]
            )
        }
    }

    public func links(noteId: String) throws -> [NoteLink] {
        try db.reader.read { db in
            try NoteLink.fetchAll(
                db,
                sql: "SELECT * FROM note_link WHERE note_id = ? ORDER BY rowid",
                arguments: [noteId]
            )
        }
    }

    public func notes(forTask taskId: String) throws -> [Note] {
        try db.reader.read { db in try Self.notes(db, column: "task_id", value: taskId) }
    }

    public func notes(forEpic epicId: String) throws -> [Note] {
        try db.reader.read { db in try Self.notes(db, column: "epic_id", value: epicId) }
    }

    static func notes(_ db: Database, column: String, value: String) throws -> [Note] {
        try Note.fetchAll(
            db,
            sql: """
            SELECT DISTINCT n.* FROM note n JOIN note_link l ON l.note_id = n.id
            WHERE l.\(column) = ? ORDER BY n.pinned DESC, n.updated_at DESC, n.title
            """,
            arguments: [value]
        )
    }

    /// Full-text search over this project's notes. `query` is FTS5 syntax; if it does not
    /// parse, every whitespace-separated token is re-tried as a quoted literal.
    public func search(projectId: String, query: String) throws -> [Note] {
        let tokens = query.split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { return [] }
        return try db.reader.read { db in
            do {
                return try matches(db, projectId: projectId, match: query)
            } catch is DatabaseError {
                let quoted = tokens.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"" }.joined(separator: " ")
                return try matches(db, projectId: projectId, match: quoted)
            }
        }
    }

    private func matches(_ db: Database, projectId: String, match: String) throws -> [Note] {
        try Note.fetchAll(
            db,
            sql: """
            SELECT n.* FROM note_fts f JOIN note n ON n.rowid = f.rowid
            WHERE f.note_fts MATCH ? AND n.project_id = ?
            ORDER BY bm25(note_fts), n.updated_at DESC
            """,
            arguments: [match, projectId]
        )
    }

    @discardableResult
    public func rename(_ id: String, title: String) throws -> Note {
        try db.writer.write { db in
            guard var note = try Note.fetchOne(db, key: id) else { throw NoteError.noteNotFound(id) }
            try unindex(db, noteId: id)
            note.title = title
            note.updatedAt = .nowMillis
            try note.update(db)
            try index(db, noteId: id)
            return note
        }
    }

    public func observe(projectId: String) -> ValueObservation<ValueReducers.Fetch<[Note]>> {
        ValueObservation.tracking { db in
            try Self.list(db, projectId: projectId)
        }
    }

    /// One note with everything the editor renders: its sections and its task/epic attachments.
    public func detail(noteId: String) throws -> NoteDetail? {
        try db.reader.read { db in try Self.detail(db, noteId: noteId) }
    }

    public func observe(noteId: String) -> ValueObservation<ValueReducers.Fetch<NoteDetail?>> {
        ValueObservation.tracking { db in try Self.detail(db, noteId: noteId) }
    }

    static func detail(_ db: Database, noteId: String) throws -> NoteDetail? {
        guard let note = try Note.fetchOne(db, key: noteId) else { return nil }
        return NoteDetail(
            note: note,
            sections: try Self.sections(db, noteId: noteId),
            links: try NoteLink.fetchAll(
                db,
                sql: "SELECT * FROM note_link WHERE note_id = ? ORDER BY rowid",
                arguments: [noteId]
            )
        )
    }
}

public struct NoteDetail: Sendable, Equatable {
    public let note: Note
    public let sections: [NoteSection]
    public let links: [NoteLink]

    public init(note: Note, sections: [NoteSection], links: [NoteLink]) {
        self.note = note
        self.sections = sections
        self.links = links
    }
}

extension NoteStore {
    static func sections(_ db: Database, noteId: String) throws -> [NoteSection] {
        try NoteSection.fetchAll(
            db,
            sql: "SELECT * FROM note_section WHERE note_id = ? ORDER BY ordering, heading",
            arguments: [noteId]
        )
    }

    func sections(_ db: Database, noteId: String) throws -> [NoteSection] {
        try Self.sections(db, noteId: noteId)
    }

    private func checkedNote(_ db: Database, _ noteId: String, _ ifVersion: Int64?) throws -> Note {
        guard let note = try Note.fetchOne(db, key: noteId) else {
            throw NoteError.noteNotFound(noteId)
        }
        if let ifVersion, ifVersion != note.version {
            throw NoteError.versionConflict(noteId: noteId, expected: ifVersion, current: note.version)
        }
        return note
    }

    private func endOrdering(_ db: Database, noteId: String) throws -> Double {
        let max = try Double.fetchOne(
            db,
            sql: "SELECT MAX(ordering) FROM note_section WHERE note_id = ?",
            arguments: [noteId]
        )
        return (max ?? 0) + 1
    }

    private func bumpVersion(_ db: Database, _ note: Note) throws -> Note {
        var note = note
        note.version += 1
        note.updatedAt = .nowMillis
        try note.update(db)
        try index(db, noteId: note.id)
        return note
    }

    /// `note_fts` is `content=''`, so nothing maintains it but us. Every mutation must
    /// `unindex` with the pre-mutation text before writing and `index` after; a delete
    /// issued with values that no longer match the indexed row corrupts the FTS index.
    private func index(_ db: Database, noteId: String) throws {
        guard let row = try indexRow(db, noteId: noteId) else { return }
        try db.execute(
            sql: "INSERT INTO note_fts(rowid, title, body) VALUES (?, ?, ?)",
            arguments: [row.rowid, row.title, row.body]
        )
    }

    private func unindex(_ db: Database, noteId: String) throws {
        guard let row = try indexRow(db, noteId: noteId) else { return }
        try db.execute(
            sql: "INSERT INTO note_fts(note_fts, rowid, title, body) VALUES ('delete', ?, ?, ?)",
            arguments: [row.rowid, row.title, row.body]
        )
    }

    private func indexRow(_ db: Database, noteId: String) throws -> (rowid: Int64, title: String, body: String)? {
        guard let row = try Row.fetchOne(db, sql: "SELECT rowid, title FROM note WHERE id = ?", arguments: [noteId]) else {
            return nil
        }
        let body = try Self.sections(db, noteId: noteId)
            .map { "\($0.heading)\n\($0.body)" }
            .joined(separator: "\n\n")
        return (row["rowid"], row["title"], body)
    }
}
