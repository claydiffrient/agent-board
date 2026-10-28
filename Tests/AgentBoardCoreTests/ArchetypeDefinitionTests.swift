@testable import AgentBoardCore
import XCTest

final class AgentDefinitionParserTests: XCTestCase {
    private func parse(_ text: String) throws -> AgentDefinition {
        try AgentDefinitionParser.parse(text, path: "/x.md").get()
    }

    func testTheFrontmatterSubsetClaudeCodeDefinitionsUse() throws {
        let full = try parse("""
        ---
        name: unit-tester
        description: Testing (Vitest/Jest, Go): behavior, not implementation
        tools: Glob, Read, Bash
        model: 'sonnet'
        color: teal
        ---

        You write unit tests.
        """)
        XCTAssertEqual(full.description, "Testing (Vitest/Jest, Go): behavior, not implementation")
        XCTAssertEqual(full.tools, ["Glob", "Read", "Bash"])
        XCTAssertEqual(full.model, "claude-sonnet-5", "a quoted short alias maps through ModelCatalog")
        XCTAssertEqual(full.systemPrompt, "You write unit tests.")
        XCTAssertEqual(full.warnings, [])

        let omitted = try parse("---\nname: a\n---\nbody")
        let empty = try parse("---\nname: a\ntools:\n---\nbody")
        XCTAssertNil(omitted.tools, "no `tools` key inherits every tool")
        XCTAssertEqual(empty.tools, [], "an empty `tools` grants none")

        let unknown = try parse("---\nname: a\nmodel: gpt-9\n---\nbody")
        XCTAssertNil(unknown.model, "an unmappable alias is no model, not a failed import")
        XCTAssertEqual(unknown.warnings.count, 1)
    }

    func testAMalformedFileIsSkippedWithADiagnosticAndTheRestOfTheDirectoryLoads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = [
            "good.md": "---\nname: good\n---\nbody",
            "plain.md": "Just some notes, no frontmatter.",
            "unclosed.md": "---\nname: unclosed\nbody",
            "block-list.md": "---\nname: listy\ntools:\n  - Read\n---\nbody",
            "nameless.md": "---\ndescription: who am I\n---\nbody",
        ]
        for (name, text) in files {
            try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        let scan = AgentDefinitionScan.read(dir)

        XCTAssertEqual(scan.definitions.map(\.name), ["good"])
        XCTAssertEqual(
            Set(scan.diagnostics.map { URL(fileURLWithPath: $0.path).lastPathComponent }),
            ["plain.md", "unclosed.md", "block-list.md", "nameless.md"],
            "a block list is refused rather than read as an empty, grant-nothing `tools`"
        )
    }
}

final class ArchetypeResolutionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ dir: String, _ file: String, _ text: String) throws {
        let url = root.appendingPathComponent(dir).appendingPathComponent(".claude/agents")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try text.write(to: url.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }

    private func board() throws -> (RosterStore, Project) {
        let db = try AppDatabase.inMemory()
        let project = try ProjectStore(db).register(
            name: "Demo", repoPath: root.appendingPathComponent("repo").path, baseBranch: "main",
            worktreeRoot: "/tmp/demo-worktrees", memoryDir: nil
        )
        return (RosterStore(db, definitions: AgentDefinitionDirectories(home: root.appendingPathComponent("home"))), project)
    }

    func testBoardLocalBeatsProjectBeatsUserAndEveryLoserIsListedAndMarked() throws {
        try write("home", "reviewer.md", "---\nname: reviewer\n---\nthe user one")
        try write("home", "writer.md", "---\nname: writer\n---\nuser only")
        try write("home", "rita.md", "---\nname: Rita\n---\nclashes with the board")
        try write("repo", "reviewer.md", "---\nname: reviewer\n---\nthe project one")
        let (roster, project) = try board()
        let rita = try roster.create(name: "Rita", role: "reviewer", systemPrompt: "board-local")

        let listed = try roster.archetypes(forProject: project.id).archetypes
        func find(_ name: String, _ label: String) -> Archetype? {
            listed.first { $0.agent.name == name && $0.source.label == label }
        }

        let reviewer = try XCTUnwrap(find("reviewer", "project"))
        XCTAssertEqual(reviewer.agent.systemPrompt, "the project one")
        XCTAssertEqual(reviewer.overrides, root.appendingPathComponent("home/.claude/agents/reviewer.md").path)
        XCTAssertNil(find("reviewer", "user"), "the user file it replaces is not offered in this project")
        XCTAssertEqual(find("writer", "user")?.source.path, root.appendingPathComponent("home/.claude/agents/writer.md").path)

        let diskRita = try XCTUnwrap(find("Rita", "user"))
        XCTAssertEqual(diskRita.shadowedBy, "Rita")
        XCTAssertFalse(diskRita.isUsable)
        XCTAssertEqual(find("Rita", "board-local")?.shadows, [diskRita.source.path!])

        for archetype in listed { try roster.enable(agentId: archetype.agent.id, forProject: project.id) }
        XCTAssertEqual(
            Set(try roster.usableAgents(forProject: project.id).map(\.id)),
            [rita.id, RosterAgent.definitionId(name: "reviewer"), RosterAgent.definitionId(name: "writer")],
            "a shadowed definition stays out of the usable set even when the project opted into it"
        )
    }

    func testEditingTheFileChangesWhatTheNextSpawnReadsWithNoReimport() throws {
        try write("home", "lit-developer.md", "---\nname: lit-developer\nmodel: sonnet\n---\nfirst")
        let (roster, project) = try board()
        let id = RosterAgent.definitionId(name: "lit-developer")
        try roster.enable(agentId: id, forProject: project.id)

        let before = try XCTUnwrap(roster.usableAgent(id, forProject: project.id))
        XCTAssertEqual(before.systemPrompt, "first")
        XCTAssertNil(before.tools)

        try write("home", "lit-developer.md", "---\nname: lit-developer\nmodel: opus\ntools: Read\n---\nsecond")

        let after = try XCTUnwrap(roster.usableAgent(id, forProject: project.id))
        XCTAssertEqual(after.systemPrompt, "second")
        XCTAssertEqual(after.model, "claude-opus-5-5")
        XCTAssertEqual(after.tools, ["Read"])
    }
}
