import AgentBoardCore
import AgentBoardRuntime
import AppKit
import Darwin
import SwiftUI
import XCTest
@testable import AgentBoard

/// Where a port row's owner name sends a click. Pure values, so these hold without a mount; the
/// end-to-end half — that the route actually selects the project — is
/// `NotificationRoutingMountTests.testARoutedBannerSelectsItsProjectTheWayTheSidebarDoes`.
final class PortOwnerLabelTests: XCTestCase {
    private func port(
        _ number: Int, ownership: PortOwnership, sessionId: String? = nil, projectId: String = "p-1",
        projectName: String? = nil, taskTitle: String? = nil, command: String = "node"
    ) -> AttributedPort {
        AttributedPort(
            port: number, pid: 4242, command: command, ownership: ownership, sessionId: sessionId,
            projectId: projectId, projectName: projectName, taskTitle: taskTitle
        )
    }

    func testALiveSessionRoutesToItsProjectAndSession() {
        let label = portOwnerLabel(
            port(3000, ownership: .liveSession, sessionId: "s-1", projectId: "p-1",
                 projectName: "Alpha", taskTitle: "Wire the thing")
        )
        XCTAssertEqual(label.title, "Wire the thing")
        XCTAssertEqual(label.detail, "Alpha")
        XCTAssertEqual(label.route, NotificationRoute(projectId: "p-1", subject: .session("s-1")))
        XCTAssertFalse(label.ended)
    }

    /// The row this epic exists for: the session ended, the socket did not. `agent_session` and
    /// `task` still hold the name, so the click still has somewhere to go.
    func testAnEndedSessionKeepsItsNameAndItsRoute() {
        let label = portOwnerLabel(
            port(5173, ownership: .orphaned, sessionId: "s-2", projectId: "p-2",
                 projectName: "Beta", taskTitle: "Ship the panel")
        )
        XCTAssertEqual(label.title, "Ship the panel")
        XCTAssertEqual(label.route, NotificationRoute(projectId: "p-2", subject: .session("s-2")))
        XCTAssertTrue(label.ended, "a ledger-sourced row must not read as a running session")
    }

    func testAShellConsolePortOpensTheProjectsTerminal() {
        let label = portOwnerLabel(
            port(4000, ownership: .shellConsole, projectId: "p-3", projectName: "Gamma")
        )
        XCTAssertEqual(label.title, "Terminal")
        XCTAssertEqual(label.route, NotificationRoute(projectId: "p-3", subject: .terminal))
        XCTAssertEqual(NotificationRoute(projectId: "p-3", subject: .terminal).screen, .terminal)
    }

    func testASessionWithNoNamedTaskFallsBackToItsShortId() {
        let label = portOwnerLabel(
            port(9000, ownership: .liveSession, sessionId: "abcdef01-2345", projectId: "p-4",
                 projectName: "Delta")
        )
        XCTAssertEqual(label.title, "Session abcdef01")
    }
}

/// The panel in the real sidebar, captured offscreen through the project's shared
/// `OffscreenMount`/`Capture` infrastructure (`OffscreenCapture.swift`).
///
/// What these prove: two mounts of the same board with the same ports are pixel-identical; each
/// added port adds pixels; an attributed row does not draw like an orphaned one; the rows land
/// above the Add Project button rather than below it; and an empty panel costs one header line.
///
/// What they cannot prove: what any of it looks like. Nobody has seen these pixels — they have only
/// been compared with each other.
@MainActor
final class PortsPanelLiveTests: XCTestCase {
    private var ledgerDir: URL!

    override func setUpWithError() throws {
        ledgerDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentboard-portspanel/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ledgerDir, withIntermediateDirectories: true)
        UserDefaults.standard.set(true, forKey: PortsPanel.expandedKey)
        SidebarCollapseState.standard.save([])
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: PortsPanel.expandedKey)
        UserDefaults.standard.removeObject(forKey: SidebarCollapseState.key)
        try? FileManager.default.removeItem(at: ledgerDir)
        super.tearDown()
    }

    /// The sidebar at its 220-point ideal, plus a margin. In points, because a capture's scale is
    /// not the same on every machine.
    private static let sidebarPoints = 0..<230

    private func register(_ db: AppDatabase, _ name: String) throws -> Project {
        try ProjectStore(db).register(
            name: name, repoPath: "/tmp/ports-\(UUID().uuidString)", baseBranch: "main",
            worktreeRoot: "/tmp/ports-worktrees", memoryDir: nil
        )
    }

    @discardableResult
    private func session(
        _ db: AppDatabase, project: Project, id: String, title: String, state: SessionState = .running
    ) throws -> String {
        let task = try TaskStore(db).create(
            projectId: project.id, title: title, body: nil, acceptance: nil, priority: nil,
            column: .running, origin: .human, epicId: nil
        )
        try SessionStore(db).insert(
            AgentSession(
                sessionId: id, projectId: project.id, taskId: task.id, role: .worker,
                cwd: "/tmp", state: state,
                endedAt: state.isActive ? nil : Int64.nowMillis - 2 * 60 * 60 * 1000
            )
        )
        return id
    }

    /// A model whose sweep is a constant, so a mount's pixels depend on the rows and nothing else.
    ///
    /// Deliberately synchronous, driven by pumping the run loop rather than by `await`. Every test
    /// in this class that was written `async` and pumped the run loop from inside the async body
    /// misbehaved: a routed selection never reached `focusChanged` after 15s of pumping, and two
    /// mounts of an identical board differed by 61,376 pixels. The same tests written synchronously
    /// pass. See the project note on offscreen SwiftUI verification.
    private func model(
        _ db: AppDatabase,
        _ rows: [ListeningPort],
        publishes: Int? = nil,
        stopOutcome: PortStopOutcome = .stopped
    ) throws -> ListeningPortModel {
        let model = ListeningPortModel(
            db: db,
            ledger: PIDSessionLedger(url: ledgerDir.appendingPathComponent("\(UUID().uuidString).json")),
            boardServerPort: { nil },
            shellConsolePIDs: { [:] },
            agentPIDs: { [:] },
            sweep: { _, _, _ in PortSweepResult(ports: rows, attributions: [:], liveIdentities: []) },
            stopper: { _, pid, _, _ in
                PortStopReport(scope: .processGroup(pid), escalated: true, outcome: stopOutcome)
            }
        )
        model.refresh()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, model.sweptAt == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(model.ports.count, publishes ?? rows.count, "the stub sweep never published its rows")
        return model
    }

    private func mount(_ db: AppDatabase, _ ports: ListeningPortModel?) -> OffscreenMount {
        OffscreenMount(
            MainWindow().environment(
                renderEnvironment(db: db, supervisor: StubSupervisor(), router: NotificationRouter(), listeningPorts: ports)
            )
        )
    }

    /// One project ("Alpha" or "Beta", every test here registers exactly one) beside the pinned rows.
    private func capture(_ mount: OffscreenMount) throws -> Capture {
        try mount.capture(
            points: Self.sidebarPoints,
            showing: SidebarContent(rows: SidebarSelection.pinned.count + 1, headers: 1)
        )
    }

    private func describe(_ box: PixelDiff) -> String { "n=\(box.count) x=\(box.minX)...\(box.maxX) y=\(box.minY)...\(box.maxY)" }

    /// The control every other assertion here rests on: nothing in this window moves on its own, so
    /// a pixel difference means the port list changed.
    func testTwoMountsOfTheSameSidebarWithTheSamePortsAreIdentical() throws {
        let db = try AppDatabase.inMemory()
        let alpha = try register(db, "Alpha")
        try session(db, project: alpha, id: "s-live", title: "Wire the thing")
        let rows = [
            ListeningPort(port: 3000, pid: 501, command: "node", sessionId: "s-live"),
            ListeningPort(port: 8080, pid: 502, command: "python3", sessionId: shellKey(alpha)),
        ]

        let first = mount(db, try model(db, rows))
        let second = mount(db, try model(db, rows))
        defer { first.close(); second.close() }
        let left = try capture(first)
        let right = try capture(second)
        let drift = left.diff(right, columns: left.columns(Self.sidebarPoints))
        XCTAssertEqual(drift.count, 0, "the ports panel must render deterministically (\(describe(drift)))")
    }

    /// One row per port, and every row above the Add Project button. Also proves the panel's empty
    /// state costs one header line and not a box, and that a row costs more pixels than that line —
    /// folding in the suite's former `testAnEmptyPanelCostsOneHeaderLineAndDrawsNoRows`, which built
    /// the same four mounts to check the same header band.
    ///
    /// Coordinate-free, because nothing in a SwiftUI sidebar is findable by name — `.help()` and
    /// the accessibility tree are both empty here. The stack sits under a list that takes the rest of
    /// the column, so it grows upward: a panel *above* Add Project leaves the button's pixels untouched when a row
    /// appears, which means the changed band never reaches below the band the empty panel occupies.
    /// A panel below the button would shove it and the change would run to the bottom of the
    /// sidebar.
    func testEachPortAddsARowAndEveryRowSitsAboveAddProject() throws {
        let db = try AppDatabase.inMemory()
        let alpha = try register(db, "Alpha")
        try session(db, project: alpha, id: "s-live", title: "Wire the thing")
        let one = [ListeningPort(port: 3000, pid: 501, command: "node", sessionId: "s-live")]
        let two = one + [ListeningPort(port: 8080, pid: 502, command: "python3", sessionId: shellKey(alpha))]

        let noPanel = mount(db, nil)
        let emptyMount = mount(db, try model(db, []))
        let oneMount = mount(db, try model(db, one))
        let twoMount = mount(db, try model(db, two))
        defer { noPanel.close(); emptyMount.close(); oneMount.close(); twoMount.close() }

        let bare = try capture(noPanel)
        let empty = try capture(emptyMount)
        let one_ = try capture(oneMount)
        let headerBand = bare.diff(empty, columns: bare.columns(Self.sidebarPoints))
        let firstRow = empty.diff(one_, columns: empty.columns(Self.sidebarPoints))
        let secondRow = one_.diff(try capture(twoMount), columns: one_.columns(Self.sidebarPoints))

        XCTAssertGreaterThan(headerBand.count, 0, "the panel header must draw")
        XCTAssertLessThan(
            headerBand.height, 60,
            "an empty panel is one line, not a box (\(describe(headerBand)))"
        )
        XCTAssertGreaterThan(firstRow.count, 0, "one listening port must draw a row")
        XCTAssertGreaterThan(
            firstRow.count, headerBand.count,
            "a panel holding a port must paint more than an empty one"
        )
        XCTAssertGreaterThan(secondRow.count, 0, "a second listening port must draw a second row")

        let addProject = try XCTUnwrap(
            bare.lowestInkedRows(columns: bare.columns(24..<168)), "the sidebar without a panel drew nothing"
        )
        XCTAssertLessThan(
            headerBand.maxY, addProject.lowerBound,
            "the panel must sit above Add Project, the lowest thing the sidebar draws without it "
                + "(header \(describe(headerBand)), Add Project y=\(addProject))"
        )
        XCTAssertLessThanOrEqual(
            firstRow.maxY, headerBand.maxY,
            "a port row must grow upward from the panel, leaving Add Project where it was "
                + "(row \(describe(firstRow)), header \(describe(headerBand)))"
        )
        XCTAssertLessThanOrEqual(
            secondRow.maxY, headerBand.maxY,
            "the second row must stay above Add Project too "
                + "(row \(describe(secondRow)), header \(describe(headerBand)))"
        )
    }

    func testAnAttributedRowDoesNotRenderLikeAnOrphanedOne() throws {
        let db = try AppDatabase.inMemory()
        let alpha = try register(db, "Alpha")
        try session(db, project: alpha, id: "s-live", title: "Wire the thing")

        let attributed = mount(
            db, try model(db, [ListeningPort(port: 3000, pid: 501, command: "node", sessionId: "s-live")])
        )
        let orphaned = mount(
            db, try model(db, [ListeningPort(port: 3000, pid: 501, command: "node", sessionId: "s-live", source: .ledger)])
        )
        defer { attributed.close(); orphaned.close() }

        let left = try capture(attributed)
        let right = try capture(orphaned)
        XCTAssertGreaterThan(
            left.diff(right, columns: left.columns(Self.sidebarPoints)).count, 0,
            "a named owner and an orphan must not draw the same row"
        )
    }

    /// A stop that did not work must not look like a stop that did. The row stays and the failure
    /// is drawn on it — which is one more line of pixels than the same row without one.
    func testARowWhoseProcessSurvivedTheEscalationDrawsItsFailure() throws {
        let db = try AppDatabase.inMemory()
        let alpha = try register(db, "Alpha")
        let rows = [ListeningPort(port: 3000, pid: 501, command: "node", sessionId: shellKey(alpha))]

        let quiet = try model(db, rows)
        let failed = try model(db, rows, stopOutcome: .stillListening)
        let quietMount = mount(db, quiet)
        let failedMount = mount(db, failed)
        defer { quietMount.close(); failedMount.close() }
        let before = try capture(failedMount)

        let row = try XCTUnwrap(failed.ports.first)
        let stopping = _Concurrency.Task { await failed.stop(row) }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, failed.stopFailure(for: row) == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        _ = stopping

        XCTAssertEqual(failed.ports.map(\.port), [3000], "the row was dropped for a process still listening")
        XCTAssertNotNil(failed.stopFailure(for: row))
        let after = try capture(failedMount)
        XCTAssertGreaterThan(
            before.diff(after, columns: before.columns(Self.sidebarPoints)).count, 0, "the failure was not drawn on the row"
        )
        let quiescent = try capture(quietMount)
        XCTAssertGreaterThan(
            quiescent.diff(after, columns: quiescent.columns(Self.sidebarPoints)).count, 0,
            "a failed row must not draw like an untouched one"
        )
    }

    /// The screenshot this rule came from: ControlCenter, keybase, steam_osx and a sibling board's
    /// server port, each drawn as an `orphaned` row on a board with no projects. A port no process
    /// the board started is holding changes no pixel, while the ended session's dev server beside it
    /// in the same sweep draws its row, names its task, and routes to its session.
    func testAPortTheBoardNeverStartedDrawsNoRowBesideAnEndedSessionsPort() throws {
        let db = try AppDatabase.inMemory()
        let beta = try register(db, "Beta")
        try session(db, project: beta, id: "s-ended", title: "Ship the panel", state: .completed)
        let orphan = ListeningPort(port: 5173, pid: 501, command: "node", sessionId: "s-ended", source: .ledger)
        let foreign = [
            ListeningPort(port: 7000, pid: 502, command: "ControlCenter", sessionId: nil),
            ListeningPort(port: 51916, pid: 503, command: "AgentBoard", sessionId: nil),
            ListeningPort(port: 9229, pid: 504, command: "node", sessionId: "s-someone-elses"),
        ]

        let orphanOnly = try model(db, [orphan])
        let mixed = try model(db, [orphan] + foreign, publishes: 1)
        let row = try XCTUnwrap(mixed.ports.first)
        XCTAssertEqual(mixed.ports.map(\.port), [5173])
        XCTAssertEqual(row.ownership, .orphaned)
        XCTAssertEqual(portOwnerLabel(row).title, "Ship the panel")
        XCTAssertEqual(
            portOwnerLabel(row).route, NotificationRoute(projectId: beta.id, subject: .session("s-ended"))
        )

        let emptyMount = mount(db, try model(db, []))
        let orphanMount = mount(db, orphanOnly)
        let mixedMount = mount(db, mixed)
        defer { emptyMount.close(); orphanMount.close(); mixedMount.close() }
        let empty = try capture(emptyMount)
        let drawn = try capture(orphanMount)

        let mixedCapture = try capture(mixedMount)
        let foreignRows = drawn.diff(mixedCapture, columns: drawn.columns(Self.sidebarPoints))
        XCTAssertEqual(foreignRows.count, 0, "a port the board never started drew a row (\(describe(foreignRows)))")
        XCTAssertGreaterThan(
            empty.diff(drawn, columns: empty.columns(Self.sidebarPoints)).count, 0,
            "the ended session's port drew no row"
        )
    }

    private func shellKey(_ project: Project) -> String {
        PortOwnerKey.shellConsole(projectId: project.id).encoded
    }
}

/// What the stop button does when it is pressed.
///
/// The rule: only a port owned by a session running *right now* asks. An accidental click on an
/// orphan costs a dev server the human can restart, and a dialog on the row this epic exists for is
/// friction on the common case. A live session is different in kind — the port may be load-bearing
/// for work in flight, and a worker that starts failing because its dev server vanished reads as a
/// bug rather than as a consequence — so that one names the task before it acts.
final class PortStopConfirmationTests: XCTestCase {
    private func port(
        _ number: Int, ownership: PortOwnership, sessionId: String? = nil, projectId: String = "p-1",
        taskTitle: String? = nil
    ) -> AttributedPort {
        AttributedPort(
            port: number, pid: 4242, command: "node", ownership: ownership, sessionId: sessionId,
            projectId: projectId, projectName: "Alpha", taskTitle: taskTitle
        )
    }

    func testALiveSessionsPortAsksFirstAndNamesTheTask() {
        let action = portStopAction(
            port(3000, ownership: .liveSession, sessionId: "s-1", projectId: "p-1",
                 taskTitle: "Wire the thing")
        )

        guard case .confirm(let confirmation) = action else {
            return XCTFail("a live session's port stopped without asking")
        }
        XCTAssertEqual(confirmation.title, "Stop :3000?")
        XCTAssertTrue(
            confirmation.message.contains("Wire the thing"),
            "the confirmation must name the task: \(confirmation.message)"
        )
    }

    func testALiveSessionWithNoNamedTaskStillAsksAndNamesItsShortId() {
        let action = portStopAction(
            port(3000, ownership: .liveSession, sessionId: "abcdef01-2345", projectId: "p-1")
        )

        guard case .confirm(let confirmation) = action else {
            return XCTFail("a live session's port stopped without asking")
        }
        XCTAssertTrue(confirmation.message.contains("abcdef01"), confirmation.message)
    }

    /// The row this epic exists for. It stops on the click.
    func testAnOrphanStopsWithoutAsking() {
        XCTAssertEqual(
            portStopAction(port(5173, ownership: .orphaned, sessionId: "s-2", projectId: "p-2",
                                taskTitle: "Ship the panel")),
            .stopNow
        )
    }

    /// The human typed the command that opened this socket and is looking at the screen that runs
    /// it, so there is nothing a dialog would tell them.
    func testAShellConsolesPortStopsWithoutAsking() {
        XCTAssertEqual(
            portStopAction(port(4000, ownership: .shellConsole, projectId: "p-3")), .stopNow
        )
    }

    func testEveryOwnershipIsCoveredSoANewOneCannotSlipThroughUnconsidered() {
        let asked = PortOwnership.allCases.filter {
            if case .confirm = portStopAction(
                port(3000, ownership: $0, sessionId: "s-1", projectId: "p-1", taskTitle: "T")
            ) { return true }
            return false
        }
        XCTAssertEqual(asked, [.liveSession])
    }
}
