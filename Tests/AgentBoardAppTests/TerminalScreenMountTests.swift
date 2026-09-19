import AgentBoardCore
import AgentBoardRuntime
import AppKit
import Foundation
import SwiftTerm
import SwiftUI
import XCTest
@testable import AgentBoard

/// What this proves: mounting `TerminalScreenView`, throwing the whole hosting view away, and
/// mounting a fresh one — which is what `.id(project.id)` does when the human leaves the project and
/// comes back — leaves the *same* `ShellConsole`, the same `LocalProcessTerminalView` and the same
/// shell pid in place. That is the scrollback surviving: it lives in the retained terminal view.
///
/// What it cannot prove: anything about the pixels. No string in the header is readable on this
/// machine (SwiftUI draws `Text` into backing layers, and the accessibility elements it publishes
/// offscreen carry no label, title or value), so the working directory and state copy are verified
/// by reading the source, not by eye.
@MainActor
final class TerminalScreenMountTests: XCTestCase {
    private var fixture: SupervisorFixture!
    private var supervisor: CountingShellSupervisor!
    private var window: NSWindow!

    override func setUp() async throws {
        fixture = try SupervisorFixture.make(gitRepo: true)
        supervisor = CountingShellSupervisor(fixture: fixture)
        NSApplication.shared.setActivationPolicy(.accessory)
        // Borderless and far offscreen: AppKit constrains a `.titled` window back onto a visible
        // screen, and this machine has none.
        window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.orderBack(nil)
    }

    override func tearDown() async throws {
        supervisor.console?.stop()
        window.contentView = nil
        window = nil
        supervisor = nil
        fixture.cleanUp()
        fixture = nil
    }

    /// A whole new `TerminalScreenView` in a whole new hosting view, exactly as returning to the
    /// project produces one.
    private func mountScreen() {
        window.contentView = NSHostingView(
            rootView: TerminalScreenView(project: fixture.project)
                .environment(AppEnvironment(db: fixture.db, supervisor: supervisor))
        )
        pump()
    }

    private func unmountScreen() {
        window.contentView = NSView()
        pump()
    }

    private func pump(turns: Int = 40) {
        for _ in 0..<turns {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            window.layoutIfNeeded()
            window.displayIfNeeded()
        }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    // MARK: - Leaving and coming back

    func testRemountingTheScreenReusesTheSameShellRatherThanForkingASecond() {
        mountScreen()
        XCTAssertTrue(waitUntil { self.supervisor.console?.state == .running }, "the screen never started a shell")
        let console = try! XCTUnwrap(supervisor.console)
        let pid = console.terminal.process.shellPid
        XCTAssertGreaterThan(pid, 0)

        unmountScreen()
        mountScreen()

        XCTAssertTrue(supervisor.console === console, "the second mount built a second console")
        XCTAssertEqual(console.terminal.process.shellPid, pid, "the second mount forked a second shell")
        XCTAssertEqual(console.state, .running)
        XCTAssertTrue(console.isProcessRunning)
        XCTAssertEqual(supervisor.shellConsoleCalls, 2, "the screen should ask once per mount and be handed the same console")
        XCTAssertEqual(supervisor.consolesBuilt, 1, "memoization is what makes the second ask cheap")
    }

    /// The terminal view holds the scrollback, so the same instance surviving the remount is the
    /// scrollback surviving it.
    func testTheRemountedScreenHostsTheVerySameTerminalView() {
        mountScreen()
        XCTAssertTrue(waitUntil { self.supervisor.console?.state == .running })
        let terminal = try! XCTUnwrap(supervisor.console).terminal
        XCTAssertTrue(hostedTerminals().contains { $0 === terminal }, "the first mount did not host the console's terminal")

        unmountScreen()
        mountScreen()

        let hosted = hostedTerminals()
        XCTAssertEqual(hosted.count, 1, "the screen hosted \(hosted.count) terminal views; exactly one belongs on screen")
        XCTAssertTrue(hosted[0] === terminal, "the remount hosted a different terminal view, so the scrollback is gone")
    }

    /// Nothing in the representable tears the process down — there is no `dismantleNSView`, and
    /// dropping the host is not a reason for the shell to die.
    func testDroppingTheHostLeavesTheShellRunning() {
        mountScreen()
        XCTAssertTrue(waitUntil { self.supervisor.console?.state == .running })
        let console = try! XCTUnwrap(supervisor.console)
        let pid = console.terminal.process.shellPid

        unmountScreen()
        pump(turns: 60)

        XCTAssertTrue(console.isProcessRunning, "leaving the screen killed the shell")
        XCTAssertEqual(console.terminal.process.shellPid, pid)
        XCTAssertEqual(console.state, .running)
    }

    // MARK: - The second guard

    /// `shellConsole(projectId:)` memoizing is not enough on its own: the memoized console of a
    /// shell the human exited is not running, so an unguarded `attach()` would silently respawn it
    /// and make `exit` look broken. The state guard is what stops that.
    func testComingBackToAShellTheHumanExitedDoesNotSilentlyRespawnIt() {
        mountScreen()
        XCTAssertTrue(waitUntil { self.supervisor.console?.state == .running })
        let console = try! XCTUnwrap(supervisor.console)

        console.terminal.send(txt: "exit 3\n")
        XCTAssertTrue(waitUntil { if case .exited = console.state { return true }; return false })

        unmountScreen()
        mountScreen()
        pump(turns: 60)

        XCTAssertEqual(console.state, .exited(3), "returning to the screen restarted a shell the human had exited")
        XCTAssertFalse(console.isProcessRunning)
        XCTAssertEqual(supervisor.consolesBuilt, 1)
    }

    func testRestartBringsTheExitedShellBackFromTheHeader() {
        mountScreen()
        XCTAssertTrue(waitUntil { self.supervisor.console?.state == .running })
        let console = try! XCTUnwrap(supervisor.console)
        console.terminal.send(txt: "exit 0\n")
        XCTAssertTrue(waitUntil { if case .exited = console.state { return true }; return false })

        // What the header's button calls.
        console.restart()

        XCTAssertEqual(console.state, .running)
        XCTAssertTrue(console.isProcessRunning)
    }

    // MARK: - Helpers

    private func hostedTerminals() -> [LocalProcessTerminalView] {
        var found: [LocalProcessTerminalView] = []
        var queue: [NSView] = window.contentView.map { [$0] } ?? []
        while let view = queue.popLast() {
            if let terminal = view as? LocalProcessTerminalView { found.append(terminal) }
            queue.append(contentsOf: view.subviews)
        }
        return found
    }
}

/// Memoizes one `ShellConsole` per project the way `WorkerSupervisor` does, but over `/bin/sh` with
/// HOME inside the fixture, so the run sources none of the developer's dotfiles. It also counts, so
/// a test can tell "asked twice, handed the same one" from "built two".
@MainActor
private final class CountingShellSupervisor: WorkerSupervising {
    private let fixture: SupervisorFixture
    private(set) var shellConsoleCalls = 0
    private(set) var consolesBuilt = 0
    private(set) var console: ShellConsole?

    init(fixture: SupervisorFixture) {
        self.fixture = fixture
    }

    func shellConsole(projectId: String) throws -> ShellConsole {
        shellConsoleCalls += 1
        if let console { return console }
        consolesBuilt += 1
        let console = ShellConsole(
            projectId: projectId,
            db: fixture.db,
            baseEnvironment: ["SHELL": "/bin/sh", "PATH": "/usr/bin:/bin", "HOME": fixture.supportDir.path]
        )
        self.console = console
        return console
    }

    var serverPort: Int? { nil }
    var lastError: String? { nil }
    var shutdownProgress: [String: ShutdownProgress] { [:] }

    func registerProject(repoPath: URL, name: String?, baseBranch: String?) async throws -> Project {
        throw StubError.notWired
    }
    func assign(taskId: String) async throws {}
    func waitForSetup() async {}
    func stop(sessionId: String) async throws {}
    func resume(sessionId: String) async throws {}
    func pauseAll(projectId: String) async throws {}
    func accept(taskId: String) async throws {}
    func reopen(taskId: String) async throws {}
    func discard(taskId: String) async throws {}
    func reconcile(projectId: String) async {}
    func attachCommand(sessionId: String) -> (executable: String, arguments: [String])? { nil }
    func worktreeDiffstat(taskId: String) async -> String? { nil }
    func worktreeDiffSummary(taskId: String) async -> DiffSummary? { nil }
    func orchestratorConsole(projectId: String) throws -> OrchestratorConsole { throw StubError.notWired }
    func approve(approvalId: String) async throws {}
    func deny(approvalId: String, reason: String?) async throws {}
    func promote(taskId: String) async throws {}
    func requestIntegration(epicId: String) async throws {}
    func epicClosurePlan(epicId: String, as closure: EpicClosure) throws -> EpicClosurePlan { throw StubError.notWired }
    func closeEpic(epicId: String, as closure: EpicClosure) async throws { throw StubError.notWired }
    func openPullRequest(epicId: String) async throws -> PullRequestOutcome { throw StubError.notWired }
    func requestShutdown(projectId: String, requestedBy: String, reason: String?) async throws -> ShutdownOrder {
        throw StubError.notWired
    }
    func cancelShutdown(projectId: String, by: String) async throws -> ShutdownOrder? { nil }
    func isShuttingDown(projectId: String) -> Bool { false }
    func deliverShutdownOrder(projectId: String) async throws -> ShutdownProgress { throw StubError.notWired }
    func requestGlobalShutdown(requestedBy: String, reason: String?) async throws -> [ShutdownOrder] { [] }
    func cancelGlobalShutdown(by: String) async throws -> [ShutdownOrder] { [] }
    func stopOrchestratorConsoles() {}
}
