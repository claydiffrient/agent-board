import AgentBoardCore
import AgentBoardRuntime
import AppKit
import Foundation
import GRDB
import SwiftTerm
import SwiftUI
import XCTest
@testable import AgentBoard

/// The human shell into a worker's worktree: where it opens, when it refuses, and what it is not
/// handed. Every directory here comes back out of the `agent_session` row, never composed from a
/// worktree base — task 36bf1b10 moved the default root, so a composed path would be a different
/// directory for a project registered before that.
@MainActor
final class WorktreeShellTests: XCTestCase {
    private var fixture: SupervisorFixture!

    override func setUp() async throws {
        fixture = try SupervisorFixture.make(gitRepo: true)
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    // MARK: - The shell opens where the session says, read from the row

    func testTheShellOpensInTheDirectoryTheSessionRowRecorded() throws {
        let task = try makeTask()
        let session = try fixture.worktreeWorker(task: task)

        let stored = try XCTUnwrap(fixture.sessions.get(session.sessionId))
        let recorded = try XCTUnwrap(stored.worktreePath)
        let availability = WorktreeShellAvailability.resolve(sessionId: stored.sessionId, session: stored)

        XCTAssertEqual(availability, .ready(path: recorded))
        XCTAssertEqual(
            WorktreeShellCommand.make(directory: try XCTUnwrap(availability.path)).directory,
            recorded,
            "the shell's working directory is not the path on the session row"
        )
    }

    /// The directory is whatever the row holds, even when that is nowhere near the project's
    /// configured worktree root — which is exactly the shape a migrated project leaves behind.
    func testAPathOutsideTheProjectsWorktreeRootIsStillWhereTheShellOpens() throws {
        let elsewhere = fixture.supportDir.appendingPathComponent("somewhere-else/old-root/abc")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let session = try insertSession(worktreePath: elsewhere.path)

        let stored = try XCTUnwrap(fixture.sessions.get(session.sessionId))
        XCTAssertFalse(
            elsewhere.path.hasPrefix(fixture.project.worktreeRoot),
            "the fixture path is under the project's root, so this test is not exercising the case"
        )
        XCTAssertEqual(
            WorktreeShellAvailability.resolve(sessionId: stored.sessionId, session: stored),
            .ready(path: elsewhere.path)
        )
    }

    func testTheShellIsTheUsersLoginShell() {
        let command = WorktreeShellCommand.make(
            directory: "/tmp",
            base: ["SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin"]
        )
        XCTAssertEqual(command.executable, "/bin/zsh")
        XCTAssertEqual(command.execName, "-zsh", "argv[0] without a leading dash is not a login shell")
    }

    // MARK: - No board authority reaches it

    /// The same assertion `ShellConsoleTests` makes for the project shell, aimed at this one: every
    /// name the board could ship authority under, pointed straight at the worktree shell.
    func testNeitherTheGrantTokenNorTheBoardPortReachesTheWorktreeShell() throws {
        let grant = try fixture.grants.issue(projectId: fixture.project.id, scope: .worker, taskId: nil)
        let port = 51_973

        var hostile = ["PATH": "/usr/bin:/bin", "SHELL": "/bin/sh"]
        for name in ChildEnvironment.boardAuthorityVariables { hostile[name] = grant.token }
        hostile["AGENTBOARD_PORT"] = "\(port)"
        hostile["AGENT_BOARD_PORT"] = "\(port)"
        hostile["AGENTBOARD_SUPPORT_DIR"] = fixture.supportDir.path

        let env = WorktreeShellCommand.make(directory: "/tmp", base: hostile).environment

        XCTAssertFalse(
            env.contains { $0.contains(grant.token) },
            "grant token \(grant.token) reached the worktree shell: \(env)"
        )
        XCTAssertFalse(
            env.contains { $0.contains("\(port)") },
            "board port \(port) reached the worktree shell: \(env)"
        )
        XCTAssertFalse(
            env.contains { $0.contains(fixture.supportDir.path) },
            "the path to the plaintext token store reached the worktree shell: \(env)"
        )
    }

    func testOpeningTheShellIssuesNoGrant() throws {
        let task = try makeTask()
        let session = try fixture.worktreeWorker(task: task)

        _ = WorktreeShellCommand.make(
            directory: try XCTUnwrap(session.worktreePath),
            base: ["SHELL": "/bin/sh", "PATH": "/usr/bin:/bin"]
        )

        let grants = try fixture.db.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM token_grant") ?? -1
        }
        XCTAssertEqual(grants, 0, "opening a human shell issued a grant")
    }

    // MARK: - Refusing rather than opening into nothing

    func testASessionWithNoWorktreeIsRefusedAndSaysWhy() throws {
        let session = try insertSession(worktreePath: nil)
        let availability = WorktreeShellAvailability.resolve(sessionId: session.sessionId, session: session)

        XCTAssertEqual(availability, .noWorktree(shortId: session.displayShortId))
        XCTAssertFalse(availability.isReady)
        XCTAssertNil(availability.path, "a session with no worktree offered a directory to open")
        XCTAssertTrue(availability.message.contains("no worktree"))
        XCTAssertFalse(WorktreeShellAvailability.canOpen(session), "the row offered a shell with no directory")
        XCTAssertTrue(WorktreeShellAvailability.buttonHelp(session).contains("no worktree"))
    }

    func testAnEmptyWorktreePathCountsAsNone() throws {
        let session = try insertSession(worktreePath: "")
        XCTAssertEqual(
            WorktreeShellAvailability.resolve(sessionId: session.sessionId, session: session),
            .noWorktree(shortId: session.displayShortId)
        )
        XCTAssertFalse(WorktreeShellAvailability.canOpen(session))
    }

    func testAWorktreeThatWasRemovedIsRefusedAndNamesThePath() throws {
        let task = try makeTask()
        let session = try fixture.worktreeWorker(task: task)
        let path = try XCTUnwrap(session.worktreePath)
        XCTAssertTrue(
            WorktreeShellAvailability.resolve(sessionId: session.sessionId, session: session).isReady,
            "the worktree was never there to begin with"
        )

        try fixture.manager.remove(path: URL(fileURLWithPath: path))

        let availability = WorktreeShellAvailability.resolve(sessionId: session.sessionId, session: session)
        XCTAssertEqual(availability, .missing(path: path))
        XCTAssertFalse(availability.isReady)
        XCTAssertTrue(availability.message.contains(path), "the refusal does not name the directory: \(availability.message)")
        XCTAssertEqual(
            try fixture.sessions.get(session.sessionId)?.worktreePath, path,
            "removal rewrote the row; this test would then be asserting on the wrong thing"
        )
    }

    func testAnUnknownSessionIsRefused() {
        let availability = WorktreeShellAvailability.resolve(sessionId: "nope", session: nil)
        XCTAssertEqual(availability, .sessionUnknown(sessionId: "nope"))
        XCTAssertTrue(availability.message.contains("nope"))
    }

    // MARK: - The refusal reaches the window, not just the enum

    /// Mounted offscreen, a refused session must host no `LocalProcessTerminalView` at all — no PTY
    /// is forked into a directory that is not there. The refusal copy itself is unreadable on this
    /// machine (SwiftUI draws `Text` into backing layers), so the strings are asserted as values
    /// above and the absence of a terminal is asserted here.
    func testARefusedSessionMountsNoTerminalAtAll() throws {
        let noWorktree = try insertSession(worktreePath: nil)
        XCTAssertEqual(terminalViews(mounting: noWorktree.sessionId), 0, "a session with no worktree forked a shell")

        let task = try makeTask()
        let removed = try fixture.worktreeWorker(task: task)
        try fixture.manager.remove(path: URL(fileURLWithPath: try XCTUnwrap(removed.worktreePath)))
        XCTAssertEqual(terminalViews(mounting: removed.sessionId), 0, "a removed worktree forked a shell")

        XCTAssertEqual(terminalViews(mounting: "no-such-session"), 0)
    }

    private func terminalViews(mounting sessionId: String) -> Int {
        NSApplication.shared.setActivationPolicy(.accessory)
        // Borderless and far offscreen: AppKit drags a `.titled` window back onto a visible screen.
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        let host = NSHostingView(
            rootView: WorktreeShellWindow(sessionId: sessionId)
                .environment(AppEnvironment(db: fixture.db, supervisor: fixture.supervisor))
        )
        window.contentView = host
        window.orderBack(nil)
        for _ in 0..<40 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            window.layoutIfNeeded()
            window.displayIfNeeded()
        }
        var found = 0
        func walk(_ view: NSView) {
            if view is LocalProcessTerminalView { found += 1 }
            view.subviews.forEach(walk)
        }
        walk(host)
        window.contentView = nil
        return found
    }

    // MARK: - The worktree vanishing underneath a running shell

    func testTheWatchReportsTheWorktreeGoingAwayWhileTheShellIsOpen() async throws {
        let task = try makeTask()
        let session = try fixture.worktreeWorker(task: task)
        let path = try XCTUnwrap(session.worktreePath)

        let watch = WorktreeWatch(path: path, interval: .milliseconds(20))
        XCTAssertTrue(watch.isPresent)
        let running = _Concurrency.Task { await watch.run() }
        defer { running.cancel() }

        try fixture.manager.remove(path: URL(fileURLWithPath: path))

        let noticed = await waitUntil { !watch.isPresent }
        XCTAssertTrue(noticed, "the shell's working directory was removed and the watch never said so")
    }

    func testTheWatchStaysQuietWhileTheWorktreeIsThere() async throws {
        let task = try makeTask()
        let session = try fixture.worktreeWorker(task: task)

        let watch = WorktreeWatch(path: try XCTUnwrap(session.worktreePath), interval: .milliseconds(20))
        let running = _Concurrency.Task { await watch.run() }
        defer { running.cancel() }

        try? await _Concurrency.Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(watch.isPresent, "the watch cried wolf over a worktree that is still on disk")
    }

    // MARK: -

    private func makeTask() throws -> BoardTask {
        try fixture.tasks.create(
            projectId: fixture.project.id, title: "Read the diff", body: nil, acceptance: nil,
            priority: nil, column: .running, origin: .human, epicId: nil
        )
    }

    private func insertSession(worktreePath: String?) throws -> AgentSession {
        let session = AgentSession(
            sessionId: "session-\(UUID().uuidString)",
            shortId: "short-1",
            projectId: fixture.project.id,
            role: .worker,
            worktreePath: worktreePath,
            cwd: fixture.project.repoPath,
            state: .completed
        )
        try fixture.sessions.insert(session)
        return session
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await _Concurrency.Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}
