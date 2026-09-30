import Foundation

/// A template an assignment instantiates in a fresh session: role, system prompt, model, tool scope
/// (SPEC §4). Board-local ones are `roster_agent` rows; disk ones are Claude Code agent definitions,
/// read at use and never editable here.
public struct Archetype: Sendable, Equatable, Identifiable {
    public enum Source: Sendable, Equatable {
        case board
        case user(path: String)
        case project(path: String)

        public var label: String {
            switch self {
            case .board: "board-local"
            case .user: "user"
            case .project: "project"
            }
        }

        public var path: String? {
            switch self {
            case .board: nil
            case .user(let path), .project(let path): path
            }
        }

        public var isEditable: Bool { self == .board }
    }

    /// The spawnable shape. For a disk archetype it is built from the file on this read.
    public var agent: RosterAgent
    public var source: Source
    public var description: String
    public var warnings: [String]
    /// A disk archetype whose name a board-local agent also has. The board-local one wins, so this
    /// one is listed but never usable.
    public var shadowedBy: String?
    /// A board-local agent's clash, from its side: the definition files it hides.
    public var shadows: [String]
    /// A project definition's clash with the user-level file of the same name, which it replaces.
    public var overrides: String?

    public var id: String { source.path ?? agent.id }
    public var isUsable: Bool { agent.enabled && shadowedBy == nil }

    public init(
        agent: RosterAgent, source: Source, description: String = "", warnings: [String] = [],
        shadowedBy: String? = nil, shadows: [String] = [], overrides: String? = nil
    ) {
        self.agent = agent
        self.source = source
        self.description = description
        self.warnings = warnings
        self.shadowedBy = shadowedBy
        self.shadows = shadows
        self.overrides = overrides
    }
}

public struct ArchetypeListing: Sendable, Equatable {
    public var archetypes: [Archetype]
    public var diagnostics: [AgentDefinitionDiagnostic]

    public static let empty = ArchetypeListing(archetypes: [], diagnostics: [])

    public init(archetypes: [Archetype], diagnostics: [AgentDefinitionDiagnostic]) {
        self.archetypes = archetypes
        self.diagnostics = diagnostics
    }
}

/// Merges board-local rows with disk definitions. Precedence, nearest the board first: board-local,
/// then project, then user. Every loser is still listed and marked, never dropped silently.
public enum ArchetypeCatalog {
    /// What one project can use: its own definitions replace user-level ones of the same name.
    public static func resolve(
        rows: [RosterAgent], user: AgentDefinitionScan, project: AgentDefinitionScan
    ) -> ArchetypeListing {
        let projectNames = Set(project.definitions.map(\.name))
        let userPaths = Dictionary(user.definitions.map { ($0.name, $0.path) }, uniquingKeysWith: { first, _ in first })
        let disk = project.definitions.map { ($0, Archetype.Source.project(path: $0.path), userPaths[$0.name]) }
            + user.definitions.filter { !projectNames.contains($0.name) }.map { ($0, Archetype.Source.user(path: $0.path), nil) }
        return listing(rows: rows, disk: disk, diagnostics: project.diagnostics + user.diagnostics)
    }

    /// The cross-project roster screen: every user definition, plus every project's own, each project
    /// definition marked with the user file it replaces inside that project.
    public static func all(
        rows: [RosterAgent], user: AgentDefinitionScan, projects: [AgentDefinitionScan]
    ) -> ArchetypeListing {
        let userPaths = Dictionary(user.definitions.map { ($0.name, $0.path) }, uniquingKeysWith: { first, _ in first })
        let disk = user.definitions.map { ($0, Archetype.Source.user(path: $0.path), String?.none) }
            + projects.flatMap(\.definitions).map { ($0, Archetype.Source.project(path: $0.path), userPaths[$0.name]) }
        return listing(rows: rows, disk: disk, diagnostics: user.diagnostics + projects.flatMap(\.diagnostics))
    }

    private static func listing(
        rows: [RosterAgent], disk: [(AgentDefinition, Archetype.Source, String?)],
        diagnostics: [AgentDefinitionDiagnostic]
    ) -> ArchetypeListing {
        let board = rows.filter { $0.definitionName == nil }
        let links = Dictionary(
            rows.compactMap { row in row.definitionName.map { ($0, row) } }, uniquingKeysWith: { first, _ in first }
        )
        let boardByName = Dictionary(board.map { ($0.name.lowercased(), $0.name) }, uniquingKeysWith: { first, _ in first })

        let fromDisk = disk.map { definition, source, overrides in
            Archetype(
                agent: agent(for: definition, link: links[definition.name]),
                source: source,
                description: definition.description,
                warnings: definition.warnings,
                shadowedBy: boardByName[definition.name.lowercased()],
                overrides: overrides
            )
        }
        let fromBoard = board.map { row in
            Archetype(
                agent: row, source: .board,
                shadows: fromDisk.filter { $0.agent.name.lowercased() == row.name.lowercased() }.compactMap(\.source.path)
            )
        }
        return ArchetypeListing(archetypes: ordered(fromBoard + fromDisk), diagnostics: diagnostics)
    }

    /// A disk archetype as the spawn path sees it. Its enabled flag lives on the pointer row, which
    /// exists only once something has written it, so a definition nobody has touched reads as enabled.
    static func agent(for definition: AgentDefinition, link: RosterAgent?) -> RosterAgent {
        RosterAgent(
            id: RosterAgent.definitionId(name: definition.name),
            name: definition.name,
            role: definition.name,
            systemPrompt: definition.systemPrompt,
            model: definition.model,
            enabled: link?.enabled ?? true,
            createdAt: link?.createdAt ?? 0,
            updatedAt: link?.updatedAt ?? 0,
            tools: definition.tools
        )
    }

    /// Usable first, then name, then source, so the two sides of a clash sit together.
    static func ordered(_ archetypes: [Archetype]) -> [Archetype] {
        func rank(_ source: Archetype.Source) -> Int {
            switch source {
            case .board: 0
            case .project: 1
            case .user: 2
            }
        }
        return archetypes.sorted { lhs, rhs in
            if lhs.isUsable != rhs.isUsable { return lhs.isUsable }
            let byName = lhs.agent.name.localizedCaseInsensitiveCompare(rhs.agent.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            if rank(lhs.source) != rank(rhs.source) { return rank(lhs.source) < rank(rhs.source) }
            return lhs.id < rhs.id
        }
    }
}
