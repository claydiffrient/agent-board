import Foundation
import GRDB

/// Why a note is being handed to a worker at spawn time (D13). A note can qualify on more
/// than one count; it is still injected once.
public enum NoteInjectionReason: String, Sendable, Equatable, CaseIterable {
    case pinned
    case task
    case epic

    public var label: String {
        switch self {
        case .pinned: "pinned for this project"
        case .task: "attached to this task"
        case .epic: "attached to this task's epic"
        }
    }

    /// Attaching a note to a task or an epic is a judgement about *this* work, so the body
    /// travels with the prompt: a note that says "do not do X" only works if it is read before
    /// X, and a worker free to skip the fetch will sometimes skip it. Pinning is a standing bet
    /// about the project rather than about this task, so a pinned note earns an index entry.
    var warrantsFullBody: Bool { self != .pinned }
}

public struct InjectedNote: Sendable, Equatable {
    public let note: Note
    public let sections: [NoteSection]
    public let reasons: [NoteInjectionReason]
    /// Carried by both of the note's fence lines, so a closing marker written inside the note body
    /// cannot pass for the real one. Fixed per fetch, so every prompt built from it fences alike.
    public let fenceId: String

    public init(
        note: Note, sections: [NoteSection], reasons: [NoteInjectionReason],
        fenceId: String = InjectedNote.newFenceId()
    ) {
        self.note = note
        self.sections = sections
        self.reasons = reasons
        self.fenceId = fenceId
    }

    public static func newFenceId() -> String {
        String(UUID().uuidString.lowercased().prefix(8))
    }
}

/// One line of the spawn prompt's note index: enough for a worker to decide whether the body is
/// worth a `resources/read` on `uri`, and nothing more.
public struct NoteIndexEntry: Sendable, Equatable {
    public let id: String
    public let title: String
    public let uri: String
    public let headings: [String]
    public let pinned: Bool

    public init(id: String, title: String, uri: String, headings: [String], pinned: Bool) {
        self.id = id
        self.title = title
        self.uri = uri
        self.headings = headings
        self.pinned = pinned
    }
}

/// What a spawning worker is told about its project's notes: the few written for this work in
/// full, and every other note as a title and a resource uri.
public struct SpawnNotes: Sendable, Equatable {
    public let full: [InjectedNote]
    public let index: [NoteIndexEntry]

    public init(full: [InjectedNote] = [], index: [NoteIndexEntry] = []) {
        self.full = full
        self.index = index
    }

    public var isEmpty: Bool { full.isEmpty && index.isEmpty }
}

extension NoteStore {
    /// What a worker on `taskId` is told about this project's notes. A note the orchestrator
    /// attached to the task or to its epic arrives in full; every other note in the project —
    /// pinned ones included — arrives as an index entry naming the resource the worker can read
    /// it from.
    public func notesForSpawn(projectId: String, taskId: String, epicId: String?) throws -> SpawnNotes {
        try db.reader.read { db in
            var reasons: [String: [NoteInjectionReason]] = [:]
            var order: [String] = []
            var byId: [String: Note] = [:]

            func absorb(_ notes: [Note], _ reason: NoteInjectionReason) {
                for note in notes where note.projectId == projectId {
                    if reasons[note.id] == nil {
                        order.append(note.id)
                        byId[note.id] = note
                    }
                    reasons[note.id, default: []].append(reason)
                }
            }

            absorb(try Note.fetchAll(
                db,
                sql: "SELECT * FROM note WHERE project_id = ? AND pinned = 1 ORDER BY updated_at DESC, title",
                arguments: [projectId]
            ), .pinned)
            absorb(try Self.notes(db, column: "task_id", value: taskId), .task)
            if let epicId {
                absorb(try Self.notes(db, column: "epic_id", value: epicId), .epic)
            }

            let fullIds = order.filter { reasons[$0]!.contains { $0.warrantsFullBody } }
            let full = try fullIds.map { id in
                InjectedNote(
                    note: byId[id]!,
                    sections: try Self.sections(db, noteId: id),
                    reasons: reasons[id]!
                )
            }

            let injected = Set(fullIds)
            let headings = try Self.headings(db, projectId: projectId)
            let index = try Self.list(db, projectId: projectId)
                .filter { !injected.contains($0.id) }
                .map { note in
                    NoteIndexEntry(
                        id: note.id,
                        title: note.title,
                        uri: NoteResourceURI.uri(projectId: note.projectId, noteId: note.id),
                        headings: headings[note.id] ?? [],
                        pinned: note.pinned
                    )
                }

            return SpawnNotes(full: full, index: index)
        }
    }
}
