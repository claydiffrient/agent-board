import Foundation

/// A Claude Code agent definition (`.claude/agents/*.md`) read as a disk-sourced archetype (SPEC §4).
public struct AgentDefinition: Sendable, Equatable {
    public var name: String
    public var description: String
    /// Nil when the frontmatter has no `tools` key, which inherits every tool. An empty list grants
    /// none; the two are opposites, not spellings of one thing.
    public var tools: [String]?
    /// A catalog model id, already resolved from the file's short alias.
    public var model: String?
    public var systemPrompt: String
    public var path: String
    /// What the file asked for that Agent Board cannot honor as written.
    public var warnings: [String]

    public init(
        name: String, description: String = "", tools: [String]? = nil, model: String? = nil,
        systemPrompt: String, path: String, warnings: [String] = []
    ) {
        self.name = name
        self.description = description
        self.tools = tools
        self.model = model
        self.systemPrompt = systemPrompt
        self.path = path
        self.warnings = warnings
    }
}

/// A definition file the scan skipped, and why. The rest of the directory still loads.
public struct AgentDefinitionDiagnostic: Error, Sendable, Equatable {
    public var path: String
    public var reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

public enum AgentDefinitionParser {
    /// Parses one definition file, or returns why it is not one.
    ///
    /// Frontmatter is the narrow subset Claude Code's own definitions use: one `key: value` scalar per
    /// line, split on the first colon so a description containing one survives. No YAML dependency;
    /// anything outside that subset, such as an indented continuation or a block list, is refused
    /// rather than half-read, because a half-read `tools` list would change what the agent may do.
    public static func parse(_ text: String, path: String) -> Result<AgentDefinition, AgentDefinitionDiagnostic> {
        func skip(_ reason: String) -> Result<AgentDefinition, AgentDefinitionDiagnostic> {
            .failure(AgentDefinitionDiagnostic(path: path, reason: reason))
        }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return skip("no frontmatter: the file does not start with `---`")
        }
        guard let close = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return skip("the frontmatter is never closed with a second `---`")
        }
        var fields: [String: String] = [:]
        for (offset, line) in lines[1..<close].enumerated() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty || line.hasPrefix("#") { continue }
            guard let colon = line.firstIndex(of: ":"), !(line.first?.isWhitespace ?? false) else {
                return skip("frontmatter line \(offset + 2) is not a one-line `key: value` scalar")
            }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            fields[key] = unquote(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        guard let name = fields["name"], !name.isEmpty else {
            return skip("the frontmatter has no `name`")
        }

        var warnings: [String] = []
        let tools = fields["tools"].map(toolList)
        for pattern in tools ?? [] where pattern.contains("(") {
            warnings.append("`\(pattern)` is a permission pattern, not a tool name; Claude Code's `--tools` drops it, "
                + "so it grants nothing")
        }
        let alias = fields["model"] ?? ""
        let model = ModelCatalog.resolve(alias: alias)
        if model == nil, !alias.isEmpty, alias != ModelCatalog.inheritAlias {
            warnings.append("model `\(alias)` is not one Agent Board knows, so the project's default model is used")
        }
        let body = lines[(close + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(AgentDefinition(
            name: name, description: fields["description"] ?? "", tools: tools, model: model,
            systemPrompt: body, path: path, warnings: warnings
        ))
    }

    static func unquote(_ value: String) -> String {
        for quote in ["\"", "'"] where value.count >= 2 && value.hasPrefix(quote) && value.hasSuffix(quote) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    /// Accepts `A, B` and the flow-list spelling `[A, B]`.
    static func toolList(_ value: String) -> [String] {
        var inner = Substring(value)
        if inner.hasPrefix("["), inner.hasSuffix("]") { inner = inner.dropFirst().dropLast() }
        return inner.split(separator: ",")
            .map { unquote($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }
}

/// Where definitions live. The user directory is fixed per machine; a project's is under its repo.
public struct AgentDefinitionDirectories: Sendable, Equatable {
    public var user: URL?
    public var readsProjects: Bool

    /// Reads nothing from disk: previews and tests that are not about definitions.
    public static let none = AgentDefinitionDirectories(user: nil, readsProjects: false)

    public init(user: URL?, readsProjects: Bool = true) {
        self.user = user
        self.readsProjects = readsProjects
    }

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.init(user: home.appendingPathComponent(".claude/agents", isDirectory: true))
    }

    public func project(repoPath: String) -> URL? {
        readsProjects ? URL(fileURLWithPath: repoPath).appendingPathComponent(".claude/agents", isDirectory: true) : nil
    }

    public func userScan() -> AgentDefinitionScan {
        user.map { AgentDefinitionScan.read($0) } ?? .empty
    }

    public func projectScan(repoPath: String) -> AgentDefinitionScan {
        project(repoPath: repoPath).map { AgentDefinitionScan.read($0) } ?? .empty
    }
}

/// One directory's definitions, read fresh on every call: there is no cache, so an edit on disk is
/// what the next listing or spawn sees.
public struct AgentDefinitionScan: Sendable, Equatable {
    public var definitions: [AgentDefinition]
    public var diagnostics: [AgentDefinitionDiagnostic]

    public static let empty = AgentDefinitionScan(definitions: [], diagnostics: [])

    public init(definitions: [AgentDefinition], diagnostics: [AgentDefinitionDiagnostic]) {
        self.definitions = definitions
        self.diagnostics = diagnostics
    }

    /// A missing directory is an empty scan, not an error. Files are read in name order, so when two
    /// files claim one name the first wins and the second is a diagnostic.
    public static func read(_ directory: URL, fileManager: FileManager = .default) -> AgentDefinitionScan {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return .empty }
        var definitions: [AgentDefinition] = []
        var diagnostics: [AgentDefinitionDiagnostic] = []
        for file in names.filter({ $0.hasSuffix(".md") }).sorted() {
            let path = directory.appendingPathComponent(file).path
            guard let data = fileManager.contents(atPath: path), let text = String(data: data, encoding: .utf8) else {
                diagnostics.append(AgentDefinitionDiagnostic(path: path, reason: "the file could not be read as UTF-8"))
                continue
            }
            switch AgentDefinitionParser.parse(text, path: path) {
            case .success(let definition):
                if let first = definitions.first(where: { $0.name == definition.name }) {
                    diagnostics.append(AgentDefinitionDiagnostic(
                        path: path, reason: "`\(definition.name)` is already defined by \(first.path)"
                    ))
                } else {
                    definitions.append(definition)
                }
            case .failure(let diagnostic):
                diagnostics.append(diagnostic)
            }
        }
        return AgentDefinitionScan(definitions: definitions, diagnostics: diagnostics)
    }
}
