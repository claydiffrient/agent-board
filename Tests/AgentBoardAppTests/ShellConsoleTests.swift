import AgentBoardCore
import AgentBoardRuntime
import Foundation
import GRDB
import XCTest
@testable import AgentBoard

@MainActor
final class ShellConsoleTests: XCTestCase {
    private var fixture: SupervisorFixture!

    override func setUp() async throws {
        fixture = try SupervisorFixture.make(gitRepo: true)
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    /// `/bin/sh` with HOME pointed at the fixture, so the shell under test sources nothing of the
    /// developer's and exits when it is told to.
    private func quietConsole() -> ShellConsole {
        ShellConsole(
            projectId: fixture.project.id,
            db: fixture.db,
            baseEnvironment: ["SHELL": "/bin/sh", "PATH": "/usr/bin:/bin", "HOME": fixture.supportDir.path]
        )
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await _Concurrency.Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    // MARK: - No board authority reaches the shell

    func testNeitherTheGrantTokenNorTheBoardPortReachesTheShell() throws {
        let grant = try fixture.grants.issue(projectId: fixture.project.id, scope: .orchestrator, taskId: nil)
        let port = 51_973

        // Every name the board could plausibly ship authority under, aimed straight at the shell.
        var hostile = ["PATH": "/usr/bin:/bin", "SHELL": "/bin/sh"]
        for name in ChildEnvironment.boardAuthorityVariables { hostile[name] = grant.token }
        hostile["AGENTBOARD_PORT"] = "\(port)"
        hostile["AGENT_BOARD_PORT"] = "\(port)"
        hostile["AGENTBOARD_SUPPORT_DIR"] = fixture.supportDir.path

        let env = ShellConsole(projectId: fixture.project.id, db: fixture.db, baseEnvironment: hostile)
            .childEnvironment()

        XCTAssertFalse(
            env.contains { $0.contains(grant.token) },
            "grant token \(grant.token) reached the human shell: \(env)"
        )
        XCTAssertFalse(
            env.contains { $0.contains("\(port)") },
            "board port \(port) reached the human shell: \(env)"
        )
        XCTAssertFalse(
            env.contains { $0.contains(fixture.supportDir.path) },
            "the path to the plaintext token store reached the human shell: \(env)"
        )
    }

    func testStartingTheShellIssuesNoGrantAndWritesNoSessionConfig() throws {
        let sessionsDir = fixture.supportDir.appendingPathComponent("sessions")
        let console = quietConsole()

        console.start()
        XCTAssertEqual(console.state, .running)

        let grantCount = try fixture.db.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM token_grant") ?? -1
        }
        XCTAssertEqual(grantCount, 0, "the shell was handed a grant")
        let configs = (try? FileManager.default.contentsOfDirectory(atPath: sessionsDir.path)) ?? []
        XCTAssertEqual(configs, [], "the shell got session config files: \(configs)")

        console.stop()
    }

    // MARK: - One console, one process, per project

    func testTheSupervisorMemoizesOneConsolePerProject() throws {
        let first = try fixture.supervisor.shellConsole(projectId: fixture.project.id)
        let second = try fixture.supervisor.shellConsole(projectId: fixture.project.id)
        XCTAssertTrue(first === second, "the supervisor built a second shell console for one project")
    }

    func testAskingTwiceStartsOneProcess() throws {
        let first = try fixture.supervisor.shellConsole(projectId: fixture.project.id)
        first.start()
        let pid = first.terminal.process.shellPid
        XCTAssertNotEqual(pid, 0)

        let second = try fixture.supervisor.shellConsole(projectId: fixture.project.id)
        second.start()

        XCTAssertEqual(second.terminal.process.shellPid, pid, "the second start forked a second shell")
        XCTAssertEqual(first.state, .running)
        first.stop()
    }

    func testAnUnknownProjectHasNoShell() {
        XCTAssertThrowsError(try fixture.supervisor.shellConsole(projectId: "no-such-project"))
    }

    // MARK: - The shell runs where the project is, as a login shell

    func testTheShellRunsTheUsersLoginShell() {
        let console = quietConsole()
        console.start()
        XCTAssertEqual(console.shellPath, "/bin/sh")
        console.stop()
    }

    func testTheShellStartsInTheProjectsRepo() async throws {
        let console = quietConsole()
        console.start()
        // The repo path is a resolved temp dir; `pwd` in the child is the only witness available
        // without a display, so it is written to a file the test can read.
        let witness = fixture.repo.appendingPathComponent("pwd.txt")
        console.terminal.send(txt: "pwd > pwd.txt\n")
        let wrote = await waitUntil { FileManager.default.fileExists(atPath: witness.path) }
        console.stop()
        XCTAssertTrue(wrote, "the shell never wrote its working directory")
        let pwd = try String(contentsOf: witness, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(
            URL(fileURLWithPath: pwd).resolvingSymlinksInPath().path,
            fixture.repo.resolvingSymlinksInPath().path
        )
    }

    // MARK: - Exit

    func testTheShellsExitShowsInTheStateAndNothingRestartsIt() async throws {
        let console = quietConsole()
        console.start()
        XCTAssertEqual(console.state, .running)

        console.terminal.send(txt: "exit 7\n")

        let exited = await waitUntil { if case .exited = console.state { return true }; return false }
        XCTAssertTrue(exited, "the shell exited and the console state never said so: \(console.state)")
        XCTAssertEqual(console.state, .exited(7), "the raw waitpid status leaked into the state")
        XCTAssertFalse(console.isProcessRunning)

        try? await _Concurrency.Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(console.state, .exited(7), "something restarted the shell behind the human's back")
    }

    func testRestartBringsAnExitedShellBack() async throws {
        let console = quietConsole()
        console.start()
        console.terminal.send(txt: "exit 0\n")
        _ = await waitUntil { if case .exited = console.state { return true }; return false }

        console.restart()

        XCTAssertEqual(console.state, .running)
        XCTAssertTrue(console.isProcessRunning)
        console.stop()
    }

    func testRestartingALiveShellReplacesIt() async throws {
        let console = quietConsole()
        console.start()
        let first = console.terminal.process.shellPid

        console.restart()

        let replaced = await waitUntil { console.isProcessRunning && console.terminal.process.shellPid != first }
        XCTAssertTrue(replaced, "restart left the original shell in place")
        XCTAssertEqual(console.state, .running)
        console.stop()
    }

    func testExitCodeDecodingMatchesTheShellConvention() {
        XCTAssertEqual(ShellConsole.exitCode(fromWaitStatus: 0), 0)
        XCTAssertEqual(ShellConsole.exitCode(fromWaitStatus: 7 << 8), 7)
        XCTAssertEqual(ShellConsole.exitCode(fromWaitStatus: SIGTERM), 128 + SIGTERM)
    }
}
