import AgentBoardCore
import AgentBoardServer
import Foundation

/// Every note in the caller's project, served as an MCP resource so an agent can see what exists
/// without paying for what it does not read. `search_notes` and `read_note` still work and are the
/// faster route for an agent that already knows which note it wants.
public struct NoteResourceHandler: ResourceHandler {
    public static let scheme = NoteResourceURI.scheme
    public static let mimeType = "application/json"

    private let notes: NoteStore

    public init(db: AppDatabase) {
        notes = NoteStore(db)
    }

    public static func uri(projectId: String, noteId: String) -> String {
        NoteResourceURI.uri(projectId: projectId, noteId: noteId)
    }

    public func resources(for identity: TokenIdentity) async throws -> [ResourceDescriptor] {
        let headings = try notes.headings(projectId: identity.projectId)
        return try notes.list(projectId: identity.projectId).map { note in
            ResourceDescriptor(
                uri: Self.uri(projectId: note.projectId, noteId: note.id),
                name: note.title,
                description: Self.describe(note, headings: headings[note.id] ?? []),
                mimeType: Self.mimeType
            )
        }
    }

    public func read(_ uri: String, identity: TokenIdentity) async throws -> [ResourceContents] {
        let noteId = try Self.noteId(from: uri, projectId: identity.projectId)
        guard let (note, sections) = try notes.read(noteId), note.projectId == identity.projectId else {
            throw ResourceError(uri: uri, message: "No note \(noteId) in this project.")
        }
        return [ResourceContents(uri: uri, mimeType: Self.mimeType, text: NoteTools.body(note, sections: sections))]
    }

    /// Enough for an agent to decide whether the body is worth fetching: whether the note is pinned,
    /// what it covers section by section, and how fresh it is.
    static func describe(_ note: Note, headings: [String]) -> String {
        var parts: [String] = []
        if note.pinned { parts.append("Pinned into every agent on this project.") }
        if headings.isEmpty {
            parts.append("No sections yet.")
        } else {
            let shown = headings.prefix(8)
            var list = shown.joined(separator: " · ")
            if headings.count > shown.count { list += " · … (\(headings.count - shown.count) more)" }
            parts.append("\(headings.count) section\(headings.count == 1 ? "" : "s"): \(list)")
        }
        parts.append("Version \(note.version), updated \(Self.day.string(from: note.updatedDate)).")
        return parts.joined(separator: " ")
    }

    static func noteId(from uri: String, projectId: String) throws -> String {
        let refusal = ResourceError(
            uri: uri,
            message: "Not a note uri. Expected \(Self.uri(projectId: projectId, noteId: "<note-id>")); "
                + "resources/list has the ones that exist."
        )
        guard let components = URLComponents(string: uri), components.scheme == scheme else { throw refusal }
        guard components.host == projectId else { throw refusal }
        let noteId = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !noteId.isEmpty, !noteId.contains("/") else { throw refusal }
        return noteId
    }

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
