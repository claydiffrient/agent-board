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
        let env = ChildEnvironment.sanitized(["CLAUDE_CODE_CHILD_SESSION": "1", "CLAUDECODE": "1", "CLAUDE_PID": "3", "PATH": "/bin", "HOME": "/h"], path: nil)
        XCTAssertEqual(env, ["PATH": "/bin", "HOME": "/h"])
    }

    func testStripsColorForcingVariables() {
        let env = ChildEnvironment.sanitized([
            "FORCE_COLOR": "3", "COLORTERM": "truecolor", "CLICOLOR_FORCE": "1",
            "TERM": "xterm-256color", "PATH": "/bin", "NO_COLOR": "1",
        ], path: nil)
        XCTAssertNil(env["FORCE_COLOR"])
        XCTAssertNil(env["COLORTERM"])
        XCTAssertNil(env["CLICOLOR_FORCE"])
        XCTAssertEqual(env, ["TERM": "xterm-256color", "PATH": "/bin", "NO_COLOR": "1"])
    }

    func testTerminalEnvironmentForcesTerm() {
        let lines = ChildEnvironment.forTerminal(["TERM": "dumb", "FORCE_COLOR": "3"], path: nil)
        XCTAssertTrue(lines.contains("TERM=xterm-256color"))
        XCTAssertTrue(lines.contains("COLORTERM=truecolor"))
        XCTAssertFalse(lines.contains { $0.hasPrefix("FORCE_COLOR=") })
        XCTAssertEqual(lines.filter { $0.hasPrefix("COLORTERM=") }, ["COLORTERM=truecolor"])
    }

    func testResolvedPathReplacesTheInheritedOne() {
        let env = ChildEnvironment.sanitized(["PATH": "/usr/bin:/bin", "HOME": "/h"], path: "/opt/homebrew/bin:/usr/bin")
        XCTAssertEqual(env, ["PATH": "/opt/homebrew/bin:/usr/bin", "HOME": "/h"])
        XCTAssertTrue(ChildEnvironment.forTerminal(["PATH": "/bin"], path: "/x:/bin").contains("PATH=/x:/bin"))
    }

    func testUnresolvedPathKeepsTheInheritedOne() {
        XCTAssertEqual(ChildEnvironment.sanitized(["PATH": "/bin"], path: nil), ["PATH": "/bin"])
    }
}

final class LoginShellPathTests: XCTestCase {
    private func fakeShell(_ body: String) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-shell-\(UUID().uuidString)")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    func testParseTakesTheLastMarkedLineOverProfileNoise() {
        let output = "Now using node v25\n__AGENTBOARD_PATH__=/decoy\nmotd\n__AGENTBOARD_PATH__=/a:/b\n"
        XCTAssertEqual(LoginShellPath.parse(output), "/a:/b")
    }

    func testParseRejectsMissingOrEmptyPath() {
        XCTAssertNil(LoginShellPath.parse("Now using node v25\n"))
        XCTAssertNil(LoginShellPath.parse("__AGENTBOARD_PATH__=\n"))
    }

    func testQueryRunsTheShellCommandAndReadsItsPath() throws {
        let shell = try fakeShell(#"echo motd; PATH=/from/profile:/usr/bin; shift 3; eval "$1""#)
        XCTAssertEqual(LoginShellPath.query(shell: shell, base: ["PATH": "/usr/bin:/bin"]), "/from/profile:/usr/bin")
    }

    func testQueryGivesUpOnAShellThatHangs() throws {
        let shell = try fakeShell("/bin/sleep 30")
        let started = Date()
        XCTAssertNil(LoginShellPath.query(shell: shell, base: [:], timeout: 0.5))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testQueryReturnsNilForAMissingShell() {
        XCTAssertNil(LoginShellPath.query(shell: "/nonexistent/shell", base: [:]))
    }

    @MainActor
    func testTerminalEnvironmentOnTheMainThreadDoesNotWaitOutASlowLoginShell() async {
        let log = EventLog()
        let release = DispatchSemaphore(value: 0)
        let lookup = LoginShellPathLookup {
            _ = release.wait(timeout: .now() + 5)
            log.append("lookup finished")
            return "/from/profile:/usr/bin"
        }

        let built = _Concurrency.Task { @MainActor in
            await ChildEnvironment.forTerminal(["PATH": "/usr/bin:/bin"], lookup: lookup)
        }
        try? await _Concurrency.Task.sleep(for: .milliseconds(100))
        log.append("main thread free")
        release.signal()
        let environment = await built.value

        XCTAssertEqual(log.events, ["main thread free", "lookup finished"])
        XCTAssertTrue(environment.contains("PATH=/from/profile:/usr/bin"))
    }

    func testEveryReaderAfterTheLookupGetsItsPath() async {
        let lookup = LoginShellPathLookup { "/from/profile:/usr/bin" }
        XCTAssertEqual(lookup.resolved, "/from/profile:/usr/bin")
        let value = await lookup.value
        XCTAssertEqual(value, "/from/profile:/usr/bin")
        XCTAssertEqual(ChildEnvironment.sanitized(["PATH": "/usr/bin"], path: lookup.resolved)["PATH"], "/from/profile:/usr/bin")
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func append(_ event: String) {
        lock.withLock { recorded.append(event) }
    }

    var events: [String] {
        lock.withLock { recorded }
    }
}
