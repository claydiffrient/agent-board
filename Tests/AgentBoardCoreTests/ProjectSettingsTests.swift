import Foundation
import XCTest
@testable import AgentBoardCore

final class ProjectSettingsTests: XCTestCase {
    func testEmptyObjectDecodesToDefaults() throws {
        let settings = try JSONDecoder().decode(ProjectSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings, ProjectSettings())
        XCTAssertEqual(settings.caps.maxConcurrentWorkers, 3)
        XCTAssertNil(settings.caps.maxTokensPerAgent)
        XCTAssertEqual(settings.caps.maxWallClockSeconds, 1800)
        XCTAssertEqual(settings.caps.maxIdleSeconds, 300)
        XCTAssertNil(settings.caps.sessionCeiling)
        XCTAssertFalse(settings.autonomyEnabled)
        XCTAssertNil(settings.autoModeJSON)
        XCTAssertEqual(settings.extraMcpServers, [])
    }

    func testPartialCapsFillMissingKeys() throws {
        let json = #"{"caps":{"maxConcurrentWorkers":1,"sessionCeiling":10},"autonomyEnabled":true}"#
        let settings = try JSONDecoder().decode(ProjectSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.caps.maxConcurrentWorkers, 1)
        XCTAssertEqual(settings.caps.sessionCeiling, 10)
        XCTAssertNil(settings.caps.maxTokensPerAgent)
        XCTAssertTrue(settings.autonomyEnabled)
    }

    func testMalformedJSONFallsBackToDefaults() {
        XCTAssertEqual(ProjectSettings.decode("not json"), ProjectSettings())
    }

    func testEncodeDecodeRoundTrip() throws {
        var settings = ProjectSettings()
        settings.autoModeJSON = #"{"rules":[]}"#
        settings.extraMcpServers = ["mdn", "caniuse"]
        settings.caps.maxIdleSeconds = 60
        XCTAssertEqual(ProjectSettings.decode(settings.encoded()), settings)
    }

    func testTaskColumnOrderAndNeighbors() {
        XCTAssertEqual(TaskColumn.allCases, [.proposed, .backlog, .ready, .running, .review, .done])
        XCTAssertEqual(TaskColumn.proposed.next, .backlog)
        XCTAssertEqual(TaskColumn.review.next, .done)
        XCTAssertNil(TaskColumn.done.next)
        XCTAssertNil(TaskColumn.proposed.previous)
        XCTAssertEqual(TaskColumn.done.index, 5)
        XCTAssertEqual(TaskOrigin.workerProposal.rawValue, "worker_proposal")
    }
}

final class ModelSettingsTests: XCTestCase {
    func testModelFieldsRoundTrip() {
        var settings = ProjectSettings()
        XCTAssertNil(settings.defaultModel)
        settings.defaultModel = "claude-sonnet-5"
        settings.modelGuidance = "Sonnet for docs"
        let decoded = ProjectSettings.decode(settings.encoded())
        XCTAssertEqual(decoded.defaultModel, "claude-sonnet-5")
        XCTAssertEqual(decoded.modelGuidance, "Sonnet for docs")
    }

    func testTaskModelPersists() throws {
        let db = try AppDatabase.inMemory()
        let project = try ProjectStore(db).register(name: "p", repoPath: "/tmp/p", baseBranch: "main", worktreeRoot: "/tmp/w", memoryDir: nil)
        let tasks = TaskStore(db)
        let withModel = try tasks.create(projectId: project.id, title: "a", body: nil, acceptance: nil, priority: nil, column: .ready, origin: .human, epicId: nil, model: "claude-haiku-4-5")
        let without = try tasks.create(projectId: project.id, title: "b", body: nil, acceptance: nil, priority: nil, column: .ready, origin: .human, epicId: nil)
        XCTAssertEqual(try tasks.get(withModel.id)?.model, "claude-haiku-4-5")
        XCTAssertNil(try tasks.get(without.id)?.model)
        var updated = withModel
        updated.model = nil
        try tasks.update(updated)
        XCTAssertNil(try tasks.get(withModel.id)?.model)
    }
}

final class DefaultAutoModeTests: XCTestCase {
    private func softDeny(_ json: String) throws -> [String] {
        let data = Data(json.utf8)
        let block = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(block["soft_deny"] as? [String])
    }

    func testDefaultBlockDeniesPushAndPullRequests() throws {
        let rules = try softDeny(ProjectSettings.defaultAutoModeJSON)
        XCTAssertEqual(rules.first, "$defaults")
        XCTAssertEqual(rules.count, 4)
        XCTAssertTrue(rules.contains { $0.contains("`git push`") })
        XCTAssertTrue(rules.contains { $0.contains("`gh pr create`") })
        XCTAssertTrue(rules.contains { $0.contains("`gh pr merge`") })
    }

    func testNewProjectSettingsCarryTheDefaultBlock() throws {
        let settings = ProjectSettings.forNewProject()
        XCTAssertEqual(settings.autoModeJSON, ProjectSettings.defaultAutoModeJSON)
        XCTAssertEqual(settings.caps, Caps())
        XCTAssertFalse(settings.autonomyEnabled)
        XCTAssertEqual(ProjectSettings.decode(settings.encoded()).autoModeJSON, ProjectSettings.defaultAutoModeJSON)
    }

    func testRegisteredProjectGetsTheDefaultBlock() throws {
        let db = try AppDatabase.inMemory()
        let projects = ProjectStore(db)
        let project = try projects.register(name: "p", repoPath: "/tmp/p", baseBranch: "main", worktreeRoot: "/tmp/w", memoryDir: nil)
        let stored = try XCTUnwrap(try projects.get(project.id)?.settings.autoModeJSON)
        let rules = try softDeny(stored)
        XCTAssertTrue(rules.contains { $0.contains("`git push`") })
        XCTAssertTrue(rules.contains { $0.contains("`gh pr create`") })
        XCTAssertTrue(rules.contains { $0.contains("`gh pr merge`") })
    }

    func testCustomAutoModeBlockIsNotClobbered() throws {
        let db = try AppDatabase.inMemory()
        let projects = ProjectStore(db)
        let project = try projects.register(name: "p", repoPath: "/tmp/p", baseBranch: "main", worktreeRoot: "/tmp/w", memoryDir: nil)

        var custom = ProjectSettings()
        custom.autoModeJSON = #"{"soft_deny":["Only Mine: nothing else"]}"#
        try projects.updateSettings(project.id, custom)

        let reloaded = try XCTUnwrap(try projects.get(project.id)?.settings)
        XCTAssertEqual(reloaded.autoModeJSON, custom.autoModeJSON)
        XCTAssertEqual(try softDeny(XCTUnwrap(reloaded.autoModeJSON)), ["Only Mine: nothing else"])
    }

    func testExistingProjectWithoutAutoModeStaysWithout() {
        let stored = #"{"caps":{"maxConcurrentWorkers":2},"autonomyEnabled":true}"#
        let settings = ProjectSettings.decode(stored)
        XCTAssertNil(settings.autoModeJSON)
        XCTAssertEqual(settings.caps.maxConcurrentWorkers, 2)
    }
}
