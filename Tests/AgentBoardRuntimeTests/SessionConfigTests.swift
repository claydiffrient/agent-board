import XCTest
import AgentBoardCore
@testable import AgentBoardRuntime

final class SessionConfigTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("agent-board-config-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func hooks(for event: String, in settings: [String: Any]) throws -> [[String: Any]] {
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        let groups = try XCTUnwrap(hooks[event] as? [[String: Any]], "missing \(event)")
        XCTAssertEqual(groups.count, 1)
        XCTAssertNil(groups[0]["matcher"])
        return try XCTUnwrap(groups[0]["hooks"] as? [[String: Any]])
    }

    func testPreToolUseHookIsRegisteredForBash() throws {
        let files = try SessionConfigWriter.write(configDir: dir, configId: "abc", port: 4321, token: "tok")
        let settings = try readJSON(files.settingsURL)
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        let groups = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0]["matcher"] as? String, "Bash")
        let hookList = try XCTUnwrap(groups[0]["hooks"] as? [[String: Any]])
        XCTAssertEqual(hookList.count, 1)
        XCTAssertEqual(hookList[0]["type"] as? String, "http")
        XCTAssertEqual(hookList[0]["url"] as? String, "http://127.0.0.1:4321/hooks?token=tok")
        XCTAssertEqual(hookList[0]["timeout"] as? Int, 5)
    }

    func testFileNamesAndShape() throws {
        let files = try SessionConfigWriter.write(configDir: dir, configId: "abc", port: 4321, token: "tok")
        XCTAssertEqual(files.settingsURL.lastPathComponent, "settings-abc.json")
        XCTAssertEqual(files.mcpConfigURL.lastPathComponent, "mcp-abc.json")

        let settings = try readJSON(files.settingsURL)
        XCTAssertNil(settings["autoMode"])
        let expectedURL = "http://127.0.0.1:4321/hooks?token=tok"

        for event in ["PostToolUse", "Notification", "Stop", "SessionEnd"] {
            let hookList = try hooks(for: event, in: settings)
            XCTAssertEqual(hookList.count, 1, event)
            XCTAssertEqual(hookList[0]["type"] as? String, "http", event)
            XCTAssertEqual(hookList[0]["url"] as? String, expectedURL, event)
            XCTAssertEqual(hookList[0]["timeout"] as? Int, 5, event)
        }

        let start = try hooks(for: "SessionStart", in: settings)
        XCTAssertEqual(start.count, 1)
        XCTAssertEqual(start[0]["type"] as? String, "command")
        let command = try XCTUnwrap(start[0]["command"] as? String)
        XCTAssertTrue(command.hasPrefix("curl "))
        XCTAssertTrue(command.contains("--data-binary @-"))
        XCTAssertTrue(command.contains("'\(expectedURL)'"))
        XCTAssertNil(start[0]["url"])

        let mcp = try readJSON(files.mcpConfigURL)
        let servers = try XCTUnwrap(mcp["mcpServers"] as? [String: Any])
        XCTAssertEqual(servers.count, 1)
        let board = try XCTUnwrap(servers["agent-board"] as? [String: Any])
        XCTAssertEqual(board["type"] as? String, "http")
        XCTAssertEqual(board["url"] as? String, "http://127.0.0.1:4321/mcp")
        XCTAssertEqual((board["headers"] as? [String: String])?["Authorization"], "Bearer tok")
    }

    func testAutoModeMergedAtTopLevel() throws {
        let autoMode = #"{"rules":[{"action":"deny","pattern":"git push"}],"environment":{"trust":"private"}}"#
        let files = try SessionConfigWriter.write(configDir: dir, configId: "a", port: 1, token: "t", autoModeJSON: autoMode)
        let settings = try readJSON(files.settingsURL)
        let block = try XCTUnwrap(settings["autoMode"] as? [String: Any])
        XCTAssertEqual((block["rules"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((block["environment"] as? [String: String])?["trust"], "private")
        XCTAssertNotNil(settings["hooks"])
    }

    func testInvalidAutoModeThrows() {
        XCTAssertThrowsError(try SessionConfigWriter.write(configDir: dir, configId: "a", port: 1, token: "t", autoModeJSON: "[1,2]"))
        XCTAssertThrowsError(try SessionConfigWriter.write(configDir: dir, configId: "a", port: 1, token: "t", autoModeJSON: "not json"))
    }

    func testExtraMcpServersMerged() throws {
        let files = try SessionConfigWriter.write(
            configDir: dir, configId: "a", port: 1, token: "t",
            extraMcpServers: [
                "mdn": #"{"type":"http","url":"https://mdn.example/mcp"}"#,
                "agent-board": #"{"type":"stdio","command":"evil"}"#,
            ]
        )
        let servers = try XCTUnwrap(readJSON(files.mcpConfigURL)["mcpServers"] as? [String: Any])
        XCTAssertEqual(servers.count, 2)
        XCTAssertEqual((servers["mdn"] as? [String: Any])?["url"] as? String, "https://mdn.example/mcp")
        XCTAssertEqual((servers["agent-board"] as? [String: Any])?["type"] as? String, "http")
    }

    func testRewriteOverwritesInPlaceWithNewPort() throws {
        let first = try SessionConfigWriter.write(configDir: dir, configId: "same", port: 1000, token: "tok")
        let second = try SessionConfigWriter.write(configDir: dir, configId: "same", port: 2000, token: "tok")
        XCTAssertEqual(first, second)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), ["mcp-same.json", "settings-same.json"])

        let settings = try readJSON(second.settingsURL)
        let stop = try hooks(for: "Stop", in: settings)
        XCTAssertEqual(stop[0]["url"] as? String, "http://127.0.0.1:2000/hooks?token=tok")
        let board = try XCTUnwrap((readJSON(second.mcpConfigURL)["mcpServers"] as? [String: Any])?["agent-board"] as? [String: Any])
        XCTAssertEqual(board["url"] as? String, "http://127.0.0.1:2000/mcp")
    }
}

final class SessionConfigDefaultAutoModeTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("agent-board-config-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testDefaultDenyRulesReachTheSessionSettingsFile() throws {
        let files = try SessionConfigWriter.write(
            configDir: dir, configId: "d", port: 7, token: "t",
            autoModeJSON: ProjectSettings.forNewProject().autoModeJSON
        )
        let settings = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: files.settingsURL)) as? [String: Any]
        )
        let block = try XCTUnwrap(settings["autoMode"] as? [String: Any])
        let rules = try XCTUnwrap(block["soft_deny"] as? [String])
        XCTAssertEqual(rules.first, "$defaults")
        XCTAssertTrue(rules.contains { $0.contains("`git push`") })
        XCTAssertTrue(rules.contains { $0.contains("`gh pr create`") })
        XCTAssertTrue(rules.contains { $0.contains("`gh pr merge`") })
        XCTAssertNotNil(settings["hooks"])
    }
}
