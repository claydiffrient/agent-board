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
}

public struct InjectedNote: Sendable, Equatable {
    public let note: Note
    public let sections: [NoteSection]
    public let reasons: [NoteInjectionReason]

    public init(note: Note, sections: [NoteSection], reasons: [NoteInjectionReason]) {
        self.note = note
        self.sections = sections
        self.reasons = reasons
    }
}

extension NoteStore {
    /// The notes a worker on `taskId` is given in full: every pinned note in the project plus
    /// every note attached to the task or its epic, each appearing once. Everything else stays
    /// pull-only behind `search_notes`.
    public func notesForSpawn(projectId: String, taskId: String, epicId: String?) throws -> [InjectedNote] {
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

            return try order.map { id in
                InjectedNote(
                    note: byId[id]!,
                    sections: try Self.sections(db, noteId: id),
                    reasons: reasons[id] ?? []
                )
            }
        }
    }
}
