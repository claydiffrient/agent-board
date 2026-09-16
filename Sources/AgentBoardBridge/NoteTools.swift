import AgentBoardCore
import AgentBoardServer
import Foundation
import GRDB

/// The notes surface shared by both scopes. The five read/write tools are worker-visible;
/// `attach_note` and `pin_note` are orchestrator-only, so `WorkerToolHandler` dispatches
/// `workerDescriptors` alone and a worker asking for either gets tool-not-found.
struct NoteTools: Sendable {
    private let db: AppDatabase
    private let notes: NoteStore
    private let tasks: TaskStore

    init(db: AppDatabase) {
        self.db = db
        notes = NoteStore(db)
        tasks = TaskStore(db)
    }

    static let workerDescriptors: [ToolDescriptor] = [
        ToolDescriptor(
            name: "search_notes",
            description: "Full-text search this project's shared notes and return the matches as id, title and current "
                + "version. Search before you decide something non-obvious: a constraint another agent already hit is "
                + "probably written down here. Use read_note to see a match in full.",
            inputSchema: ToolSchema.object(
                properties: ["query": ToolSchema.string("Words to match. FTS5 syntax is accepted.")],
                required: ["query"]
            )
        ),
        ToolDescriptor(
            name: "read_note",
            description: "Read one note in full: every section, plus the note's current version. Pass that version back as "
                + "`if_version` when you write to the note, so a concurrent write cannot be silently overwritten.",
            inputSchema: ToolSchema.object(
                properties: ["id": ToolSchema.string("Note id from search_notes.")],
                required: ["id"]
            )
        ),
        ToolDescriptor(
            name: "append_section",
            description: "Add to a note. If `heading` already exists its body is kept and yours is appended after a blank "
                + "line; otherwise a new section is added at the end. Prefer this over replace_section: it cannot lose "
                + "another agent's text.",
            inputSchema: ToolSchema.object(
                properties: [
                    "note_id": ToolSchema.string(),
                    "heading": ToolSchema.string("Section heading, without leading '#'."),
                    "body": ToolSchema.string(),
                    "if_version": ToolSchema.integer(
                        "The version read_note returned. The write is refused if the note has changed since."
                    ),
                ],
                required: ["note_id", "heading", "body"]
            )
        ),
        ToolDescriptor(
            name: "replace_section",
            description: "Replace one section's body outright, creating the section if it does not exist. This discards "
                + "whatever that section said; use it only to correct text you know is wrong, and pass `if_version` so "
                + "you cannot overwrite a write you have not seen.",
            inputSchema: ToolSchema.object(
                properties: [
                    "note_id": ToolSchema.string(),
                    "heading": ToolSchema.string("Section heading, without leading '#'."),
                    "body": ToolSchema.string(),
                    "if_version": ToolSchema.integer(
                        "The version read_note returned. The write is refused if the note has changed since."
                    ),
                ],
                required: ["note_id", "heading", "body"]
            )
        ),
        ToolDescriptor(
            name: "create_note",
            description: "Create a note in this project's shared notes. Search first — adding a second note on a subject "
                + "that already has one splits the answer. The note starts unpinned and attached to nothing.",
            inputSchema: ToolSchema.object(
                properties: [
                    "title": ToolSchema.string("What the note is about."),
                    "sections": ToolSchema.objectArray(
                        properties: ["heading": ToolSchema.string(), "body": ToolSchema.string()],
                        required: ["heading", "body"],
                        description: "Sections in order. A note with no sections is allowed but not useful."
                    ),
                ],
                required: ["title"]
            )
        ),
    ]

    static let orchestratorDescriptors: [ToolDescriptor] = workerDescriptors + [
        ToolDescriptor(
            name: "attach_note",
            description: "Attach a note to a task or an epic. Every worker spawned on that task, or on a task in that "
                + "epic, is given the note in full at spawn time. Pass exactly one of task_id or epic_id.",
            inputSchema: ToolSchema.object(
                properties: [
                    "note_id": ToolSchema.string(),
                    "task_id": ToolSchema.string(),
                    "epic_id": ToolSchema.string(),
                ],
                required: ["note_id"]
            )
        ),
        ToolDescriptor(
            name: "pin_note",
            description: "Pin or unpin a note. A pinned note is named, with its resource uri, in the note index "
                + "every future agent on this project is spawned with, so an agent can fetch it when the subject "
                + "comes up; its text is not pasted into the prompt. Unpin it once it stops being true.",
            inputSchema: ToolSchema.object(
                properties: ["note_id": ToolSchema.string(), "pinned": ToolSchema.boolean()],
                required: ["note_id", "pinned"]
            )
        ),
    ]

    func call(_ name: String, arguments: JSONValue, identity: TokenIdentity) throws -> ToolResult {
        switch name {
        case "search_notes":
            let query = try ToolArguments.requiredString("query", in: arguments)
            let matches = try notes.search(projectId: identity.projectId, query: query)
            return .json(.array(matches.map(Self.renderSummary)))
        case "read_note":
            let note = try projectNote(try ToolArguments.requiredString("id", in: arguments), identity: identity)
            guard let (_, sections) = try notes.read(note.id) else {
                throw ToolError("Note \(note.id) is not in this project.")
            }
            return ToolResult(text: Self.body(note, sections: sections))
        case "append_section":
            return try write(arguments, identity: identity) { noteId, heading, body, ifVersion in
                try notes.appendSection(
                    noteId: noteId, heading: heading, body: body,
                    ifVersion: ifVersion, writtenBy: identity.sessionId
                )
            }
        case "replace_section":
            return try write(arguments, identity: identity) { noteId, heading, body, ifVersion in
                try notes.replaceSection(
                    noteId: noteId, heading: heading, body: body,
                    ifVersion: ifVersion, writtenBy: identity.sessionId
                )
            }
        case "create_note":
            let title = try ToolArguments.requiredString("title", in: arguments)
            let note = try notes.create(
                projectId: identity.projectId,
                title: title,
                sections: try Self.parseSections(arguments["sections"]),
                writtenBy: identity.sessionId
            )
            return .json(Self.renderSummary(note))
        case "attach_note":
            return try attach(arguments, identity: identity)
        case "pin_note":
            let note = try projectNote(try ToolArguments.requiredString("note_id", in: arguments), identity: identity)
            let pinned = try ToolArguments.requiredBool("pinned", in: arguments)
            try notes.pin(note.id, pinned)
            return ToolResult(text: pinned
                ? "Pinned \"\(note.title)\". Every agent spawned on this project from now on sees it in full."
                : "Unpinned \"\(note.title)\".")
        default:
            throw ToolError("Unknown tool: \(name)")
        }
    }

    private func write(
        _ arguments: JSONValue,
        identity: TokenIdentity,
        _ apply: (String, String, String, Int64?) throws -> Note
    ) throws -> ToolResult {
        let note = try projectNote(try ToolArguments.requiredString("note_id", in: arguments), identity: identity)
        let heading = try ToolArguments.requiredString("heading", in: arguments)
        let body = try ToolArguments.requiredString("body", in: arguments)
        let ifVersion = try ToolArguments.optionalInteger("if_version", in: arguments)
        do {
            let updated = try apply(note.id, heading, body, ifVersion)
            return .json(Self.renderSummary(updated))
        } catch let error as NoteError {
            throw Self.toolError(error)
        }
    }

    private func attach(_ arguments: JSONValue, identity: TokenIdentity) throws -> ToolResult {
        let note = try projectNote(try ToolArguments.requiredString("note_id", in: arguments), identity: identity)
        let taskId = ToolArguments.optionalString("task_id", in: arguments)
        let epicId = ToolArguments.optionalString("epic_id", in: arguments)
        switch (taskId, epicId) {
        case (nil, nil):
            throw ToolError("Pass task_id or epic_id: a note has to be attached to something.")
        case (.some, .some):
            throw ToolError("Pass task_id or epic_id, not both.")
        case (.some(let taskId), nil):
            guard let task = try tasks.get(taskId), task.projectId == identity.projectId else {
                throw ToolError("Task \(taskId) is not in this project.")
            }
            try notes.attach(noteId: note.id, taskId: taskId)
            return ToolResult(text: "Attached \"\(note.title)\" to task \(taskId). Workers spawned on it will see it in full.")
        case (nil, .some(let epicId)):
            let owner = try db.reader.read { db in
                try String.fetchOne(db, sql: "SELECT project_id FROM epic WHERE id = ?", arguments: [epicId])
            }
            guard owner == identity.projectId else {
                throw ToolError("Epic \(epicId) is not in this project.")
            }
            try notes.attach(noteId: note.id, epicId: epicId)
            return ToolResult(text: "Attached \"\(note.title)\" to epic \(epicId). Workers on its tasks will see it in full.")
        }
    }

    private func projectNote(_ id: String, identity: TokenIdentity) throws -> Note {
        guard let note = try notes.get(id), note.projectId == identity.projectId else {
            throw ToolError("Note \(id) is not in this project.")
        }
        return note
    }

    static func toolError(_ error: NoteError) -> ToolError {
        switch error {
        case .noteNotFound(let id):
            return ToolError("Note \(id) no longer exists.")
        case .versionConflict(let noteId, let expected, let current):
            return ToolError(
                "Version conflict on note \(noteId): you wrote against version \(expected) but it is now at version "
                    + "\(current). Nothing was written. Call read_note(\"\(noteId)\") to see the current text, then "
                    + "retry with if_version \(current)."
            )
        }
    }

    static func parseSections(_ value: JSONValue?) throws -> [(heading: String, body: String)] {
        guard let value, value != .null else { return [] }
        guard let items = value.arrayValue else {
            throw ToolError("Argument sections must be an array of {heading, body} objects.")
        }
        return try items.map { item in
            guard let heading = item["heading"]?.stringValue, !heading.isEmpty else {
                throw ToolError("Every entry in sections needs a non-empty heading.")
            }
            return (heading: heading, body: item["body"]?.stringValue ?? "")
        }
    }

    static func renderSummary(_ note: Note) -> JSONValue {
        .object([
            "id": .string(note.id),
            "title": .string(note.title),
            "pinned": .bool(note.pinned),
            "version": .number(Double(note.version)),
            "updated_at": .millis(note.updatedAt),
        ])
    }

    /// The one assembly of a note's full text. `read_note` and the `note://` resource both call it,
    /// so the tool and the resource cannot drift apart.
    static func body(_ note: Note, sections: [NoteSection]) -> String {
        ToolResult.json(render(note, sections: sections)).text
    }

    static func render(_ note: Note, sections: [NoteSection]) -> JSONValue {
        guard case .object(var object) = renderSummary(note) else { return .null }
        object["sections"] = .array(sections.map { section in
            var fields: [String: JSONValue] = ["heading": .string(section.heading), "body": .string(section.body)]
            if let writtenBy = section.writtenBy { fields["written_by"] = .string(writtenBy) }
            return .object(fields)
        })
        return .object(object)
    }
}
