import XCTest
@testable import AgentBoardRuntime

final class ClaudeCLITests: XCTestCase {
    func testParseShortIdWithName() {
        let stdout = "backgrounded · 3f9a1c2b · fix-login-bug\n"
        XCTAssertEqual(ClaudeCLI.parseShortId(from: stdout), "3f9a1c2b")
    }

    func testParseShortIdWithoutName() {
        XCTAssertEqual(ClaudeCLI.parseShortId(from: "backgrounded · deadbeef"), "deadbeef")
    }

    func testParseShortIdSkipsNoiseLines() {
        let stdout = "warning: --bg manages the session id\nbackgrounded · 0a1b2c3d · worker\n"
        XCTAssertEqual(ClaudeCLI.parseShortId(from: stdout), "0a1b2c3d")
    }

    func testParseShortIdStripsANSIColor() {
        let stdout = """
        backgrounded \u{1B}[2m·\u{1B}[22m \u{1B}[36m5a359bd9\u{1B}[39m \u{1B}[2m·\u{1B}[22m add-hello-txt
        \u{1B}[2m  claude agents             list sessions\u{1B}[22m
        """
        XCTAssertEqual(ClaudeCLI.parseShortId(from: stdout), "5a359bd9")
    }

    func testParseShortIdRejectsNonHexAndMissing() {
        XCTAssertNil(ClaudeCLI.parseShortId(from: "backgrounded · not-hex · name"))
        XCTAssertNil(ClaudeCLI.parseShortId(from: "backgrounded ·  · name"))
        XCTAssertNil(ClaudeCLI.parseShortId(from: "session started 3f9a1c2b"))
        XCTAssertNil(ClaudeCLI.parseShortId(from: ""))
    }

    func testParseShortIdStripsANSIColorCodes() {
        let stdout = "\u{1B}[2K\u{1B}[1mbackgrounded\u{1B}[0m \u{B7} \u{1B}[36m3f9a1c2b\u{1B}[0m \u{B7} \u{1B}[32mfix-login-bug\u{1B}[0m\n"
        XCTAssertEqual(ClaudeCLI.parseShortId(from: stdout), "3f9a1c2b")
    }

    func testParseShortIdStripsOSCAndCursorSequences() {
        let stdout = "\u{1B}]0;claude\u{07}\u{1B}[?25l\u{1B}[38;5;208mbackgrounded \u{B7} deadbeef\u{1B}[0m\n"
        XCTAssertEqual(ClaudeCLI.parseShortId(from: stdout), "deadbeef")
    }

    func testStrippingANSIEscapesLeavesPlainTextAlone() {
        XCTAssertEqual(ClaudeCLI.strippingANSIEscapes("backgrounded \u{B7} abc"), "backgrounded \u{B7} abc")
        XCTAssertEqual(ClaudeCLI.strippingANSIEscapes("a\u{1B}[31mb\u{1B}[0mc"), "abc")
    }

    func testRecoveredAgentMatchesCwdNameAndLaunchTime() {
        let launchedAt = Date(timeIntervalSince1970: 1_788_000_000)
        let cwd = URL(fileURLWithPath: "/wt/task-1")
        let match = AgentInfo(
            id: "aa11bb22", cwd: "/wt/task-1", kind: "background", sessionId: "S-match",
            name: "task-1", startedAt: launchedAt.timeIntervalSince1970 * 1000 + 500
        )
        let agents = [
            AgentInfo(id: "cc33", cwd: "/wt/task-2", kind: "background", sessionId: "S-other-cwd",
                      name: "task-1", startedAt: match.startedAt),
            AgentInfo(id: "dd44", cwd: "/wt/task-1", kind: "background", sessionId: "S-other-name",
                      name: "task-9", startedAt: match.startedAt),
            AgentInfo(id: "ee55", cwd: "/wt/task-1", kind: "background", sessionId: "S-stale",
                      name: "task-1", startedAt: (launchedAt.timeIntervalSince1970 - 600) * 1000),
            AgentInfo(cwd: "/wt/task-1", kind: "interactive", sessionId: "S-interactive",
                      name: "task-1", pid: 99, startedAt: match.startedAt),
            match,
        ]
        let recovered = ClaudeCLI.recoveredAgent(from: agents, cwd: cwd, name: "task-1", launchedAt: launchedAt)
        XCTAssertEqual(recovered?.sessionId, "S-match")
        XCTAssertEqual(recovered?.id, "aa11bb22")
    }

    func testRecoveredAgentReturnsNilWhenNothingMatches() {
        let launchedAt = Date(timeIntervalSince1970: 1_788_000_000)
        let agents = [
            AgentInfo(id: "aa11", cwd: "/wt/task-1", kind: "background", sessionId: "S",
                      name: "task-1", startedAt: (launchedAt.timeIntervalSince1970 - 60) * 1000)
        ]
        XCTAssertNil(ClaudeCLI.recoveredAgent(
            from: agents, cwd: URL(fileURLWithPath: "/wt/task-1"), name: "task-1", launchedAt: launchedAt
        ))
    }

    func testAgentInfoDecodesBothShapes() throws {
        let json = """
        [
          {"id":"eda73d8f","cwd":"/tmp/a","kind":"background","startedAt":1786984943202,
           "sessionId":"eda73d8f-f4c6-4d7b-8abf-e3fab0a96314","name":"n","state":"stopped"},
          {"pid":84727,"cwd":"/tmp/b","kind":"interactive","startedAt":1788497703208,
           "sessionId":"929a9f85-611f-43df-b8da-58c33407d3a0","name":"m","status":"idle"}
        ]
        """
        let agents = try JSONDecoder().decode([AgentInfo].self, from: Data(json.utf8))
        XCTAssertEqual(agents.count, 2)
        XCTAssertEqual(agents[0].id, "eda73d8f")
        XCTAssertEqual(agents[0].state, "stopped")
        XCTAssertNil(agents[0].pid)
        XCTAssertEqual(agents[1].pid, 84727)
        XCTAssertEqual(agents[1].status, "idle")
        XCTAssertNil(agents[1].id)
        XCTAssertEqual(agents[0].startedDate?.timeIntervalSince1970 ?? 0, 1786984943.202, accuracy: 0.001)
    }

    func testSpawnArgumentsOrder() {
        let files = SessionConfigFiles(
            settingsURL: URL(fileURLWithPath: "/cfg/settings-x.json"),
            mcpConfigURL: URL(fileURLWithPath: "/cfg/mcp-x.json")
        )
        let request = SpawnRequest(
            cwd: URL(fileURLWithPath: "/wt"),
            name: "task-1",
            prompt: "Do the thing",
            configFiles: files,
            appendSystemPrompt: "You are a worker.",
            model: "claude-sonnet-5"
        )
        let args = BackgroundSessionRuntime.arguments(for: request)
        XCTAssertEqual(args.first, "Do the thing")
        XCTAssertEqual(args, [
            "Do the thing",
            "--bg",
            "-n", "task-1",
            "--permission-mode", "auto",
            "--strict-mcp-config",
            "--mcp-config", "/cfg/mcp-x.json",
            "--settings", "/cfg/settings-x.json",
            "--append-system-prompt", "You are a worker.",
            "--model", "claude-sonnet-5",
            "--disallowedTools", "Bash(git push*)", "Bash(gh pr create*)", "Bash(gh pr merge*)",
        ])
        XCTAssertEqual(args.firstIndex(of: "--disallowedTools").map { args.count - $0 }, 4)
    }

    func testSpawnArgumentsOmitOptionalFlags() {
        let files = SessionConfigFiles(
            settingsURL: URL(fileURLWithPath: "/cfg/s.json"),
            mcpConfigURL: URL(fileURLWithPath: "/cfg/m.json")
        )
        let request = SpawnRequest(cwd: URL(fileURLWithPath: "/wt"), name: "n", prompt: "p", configFiles: files, disallowedTools: [])
        let args = BackgroundSessionRuntime.arguments(for: request)
        XCTAssertFalse(args.contains("--append-system-prompt"))
        XCTAssertFalse(args.contains("--model"))
        XCTAssertFalse(args.contains("--disallowedTools"))
        XCTAssertEqual(args.last, "/cfg/s.json")
    }

    func testAttachCommandTargetsClaude() {
        let command = BackgroundSessionRuntime().attachCommand(shortId: "abc12345")
        XCTAssertEqual(command.arguments.suffix(2), ["attach", "abc12345"])
        XCTAssertTrue(command.executable.hasSuffix("/claude") || command.executable == "/usr/bin/env")
        if command.executable == "/usr/bin/env" {
            XCTAssertEqual(command.arguments.first, "claude")
        }
    }
}
