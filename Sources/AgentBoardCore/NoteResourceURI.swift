import Foundation

/// The MCP resource address of a note. It lives here rather than beside the resource handler
/// because the spawn prompt's note index has to name uris the handler will accept.
public enum NoteResourceURI {
    public static let scheme = "note"

    /// `note://<project-id>/<note-id>` — both ids are immutable, so the uri survives a retitle,
    /// an edit and a pin.
    public static func uri(projectId: String, noteId: String) -> String {
        "\(scheme)://\(projectId)/\(noteId)"
    }
}
