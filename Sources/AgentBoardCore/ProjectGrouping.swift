import Foundation

/// One sidebar section: a workspace and its projects, or the trailing ungrouped run
/// when `workspace` is nil.
public struct ProjectSection: Identifiable, Sendable, Equatable {
    public static let ungroupedId = "__ungrouped__"

    public var workspace: Workspace?
    public var projects: [Project]

    public init(workspace: Workspace?, projects: [Project]) {
        self.workspace = workspace
        self.projects = projects
    }

    public var id: String { workspace?.id ?? Self.ungroupedId }
    public var isUngrouped: Bool { workspace == nil }
}

public enum ProjectGrouping {
    /// Sections in `ordering` order, each keeping the incoming order of its projects.
    /// Empty workspaces stay (they are drop targets); the ungrouped section is appended
    /// only when something landed in it, including projects whose `workspaceId` names a
    /// workspace that no longer exists.
    public static func sections(projects: [Project], workspaces: [Workspace]) -> [ProjectSection] {
        let ordered = workspaces.sorted {
            if $0.ordering != $1.ordering { return $0.ordering < $1.ordering }
            let byName = $0.name.localizedCaseInsensitiveCompare($1.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return $0.id < $1.id
        }

        var grouped: [String: [Project]] = [:]
        var ungrouped: [Project] = []
        let known = Set(ordered.map(\.id))
        for project in projects {
            if let workspaceId = project.workspaceId, known.contains(workspaceId) {
                grouped[workspaceId, default: []].append(project)
            } else {
                ungrouped.append(project)
            }
        }

        var sections = ordered.map { ProjectSection(workspace: $0, projects: grouped[$0.id] ?? []) }
        if !ungrouped.isEmpty {
            sections.append(ProjectSection(workspace: nil, projects: ungrouped))
        }
        return sections
    }
}
