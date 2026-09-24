import AgentBoardCore
import Foundation

/// What the Status pane's search reaches (SPEC §10, Searching the Status pane). One field narrows
/// the roster and the ports section together; a row matches when every term appears somewhere
/// among that row's fields.
enum StatusSearch {
    /// The short id, task title, role label (so the rostered agent's name), state as drawn and as
    /// stored, and the model's id and display name. Not the last tool, which changes under the
    /// query while the session works, and not the full session id.
    static func fields(of session: AgentSession, taskTitle: String?, roleLabel: String) -> [String?] {
        [
            session.displayShortId,
            taskTitle,
            roleLabel,
            session.state.label,
            session.state.rawValue,
            session.model,
            ModelCatalog.option(for: session.model)?.name,
        ]
    }

    /// The port as drawn (`:3000`), the command, and the owner's title: its task, `Session …`, or
    /// `Terminal`. Not the project name, which every port on one project's pane shares.
    static func fields(of port: AttributedPort) -> [String?] {
        [":\(port.port)", port.command, portOwnerLabel(port).title]
    }

    /// What follows the session count beside the field. Search does not reach past **Show ended**,
    /// the way the Task Board's does not reach past Show Archived: a hidden match is counted instead.
    static func note(hiddenEndedMatches: Int, shownPorts: Int, totalPorts: Int) -> String? {
        let ended: String? = switch hiddenEndedMatches {
        case ..<1: nil
        case 1: "1 ended match hidden"
        default: "\(hiddenEndedMatches) ended matches hidden"
        }
        let ports: String? = switch (shownPorts, totalPorts) {
        case (_, ..<1): nil
        case (..<1, _): "no ports match"
        default: "\(shownPorts) of \(totalPorts) \(totalPorts == 1 ? "port" : "ports")"
        }
        let parts = [ended, ports].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension SearchNoun {
    static let sessions = SearchNoun(one: "session", many: "sessions", prompt: "Search sessions and ports")
}
