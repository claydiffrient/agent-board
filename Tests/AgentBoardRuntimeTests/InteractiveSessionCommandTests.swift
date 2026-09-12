import XCTest
@testable import AgentBoardRuntime

final class InteractiveSessionCommandTests: XCTestCase {
    private let files = SessionConfigFiles(
        settingsURL: URL(fileURLWithPath: "/tmp/settings-x.json"),
        mcpConfigURL: URL(fileURLWithPath: "/tmp/mcp-x.json")
    )

    func testFreshLaunchPinsSessionIdAndOmitsStrict() {
        let command = InteractiveSessionCommand(sessionId: "abc", cwd: URL(fileURLWithPath: "/repo"), configFiles: files, appendSystemPrompt: "rules", model: "claude-opus-5")
        let args = command.arguments(resume: false)
        XCTAssertEqual(Array(args.suffix(10)), ["--session-id", "abc", "--mcp-config", "/tmp/mcp-x.json", "--settings", "/tmp/settings-x.json", "--append-system-prompt", "rules", "--model", "claude-opus-5"])
        XCTAssertTrue(args.contains("--session-id"))
        XCTAssertFalse(args.contains("--resume"))
        XCTAssertFalse(args.contains("--strict-mcp-config"))
        XCTAssertEqual(args.last, "claude-opus-5")
    }

    func testResumeUsesResumeFlag() {
        let command = InteractiveSessionCommand(sessionId: "abc", cwd: URL(fileURLWithPath: "/repo"), configFiles: files, appendSystemPrompt: "rules")
        let args = command.arguments(resume: true)
        XCTAssertTrue(args.contains("--resume"))
        XCTAssertFalse(args.contains("--session-id"))
        XCTAssertFalse(args.contains("--model"))
    }

    func testTranscriptDetection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cwd = URL(fileURLWithPath: "/Users/x/proj")
        let transcript = ClaudeProjectPaths.transcriptURL(forCwd: cwd.path, sessionId: "s1", projectsRoot: root)
        XCTAssertEqual(transcript.lastPathComponent, "s1.jsonl")
        XCTAssertEqual(transcript.deletingLastPathComponent().lastPathComponent, "-Users-x-proj")
    }

    func testUserPromptSubmitHookIsEmitted() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let files = try SessionConfigWriter.write(configDir: dir, configId: "c", port: 1234, token: "t", autoModeJSON: nil, extraMcpServers: nil)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: files.settingsURL)) as! [String: Any]
        let hooks = json["hooks"] as! [String: Any]
        XCTAssertNotNil(hooks["UserPromptSubmit"])
    }
}

final class ChildEnvironmentTests: XCTestCase {
    func testStripsClaudeCodeMarkers() {
        let env = ChildEnvironment.sanitized(["CLAUDE_CODE_CHILD_SESSION": "1", "CLAUDECODE": "1", "CLAUDE_PID": "3", "PATH": "/bin", "HOME": "/h"])
        XCTAssertEqual(env, ["PATH": "/bin", "HOME": "/h"])
    }

    func testStripsColorForcingVariables() {
        let env = ChildEnvironment.sanitized([
            "FORCE_COLOR": "3", "COLORTERM": "truecolor", "CLICOLOR_FORCE": "1",
            "TERM": "xterm-256color", "PATH": "/bin", "NO_COLOR": "1",
        ])
        XCTAssertNil(env["FORCE_COLOR"])
        XCTAssertNil(env["COLORTERM"])
        XCTAssertNil(env["CLICOLOR_FORCE"])
        XCTAssertEqual(env, ["TERM": "xterm-256color", "PATH": "/bin", "NO_COLOR": "1"])
    }

    func testTerminalEnvironmentForcesTerm() {
        let lines = ChildEnvironment.forTerminal(["TERM": "dumb", "FORCE_COLOR": "3"])
        XCTAssertTrue(lines.contains("TERM=xterm-256color"))
        XCTAssertTrue(lines.contains("COLORTERM=truecolor"))
        XCTAssertFalse(lines.contains { $0.hasPrefix("FORCE_COLOR=") })
        XCTAssertEqual(lines.filter { $0.hasPrefix("COLORTERM=") }, ["COLORTERM=truecolor"])
    }
}
