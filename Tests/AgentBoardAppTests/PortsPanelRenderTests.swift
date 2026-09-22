import AgentBoardCore
import AgentBoardRuntime
import AppKit
import Darwin
import SwiftUI
import XCTest
@testable import AgentBoard

/// Where a port row's owner name sends a click. Pure values, so these hold without a mount; the
/// end-to-end half — that the route actually selects the project — is
/// `PortsPanelLiveTests.testAnAttributedOwnerNameSelectsItsProject`.
final class PortOwnerLabelTests: XCTestCase {
    private func port(
        _ number: Int, ownership: PortOwnership, sessionId: String? = nil, projectId: String? = nil,
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

    func testAnOrphanNamesNobodyAndRoutesNowhere() {
        let label = portOwnerLabel(port(8080, ownership: .unattributed, command: "python3"))
        XCTAssertEqual(label.title, "orphaned")
        XCTAssertEqual(label.detail, "python3", "the command is all there is to say")
        XCTAssertNil(label.route, "there is no session to open, so the name is not a link")
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

/// The panel in the real sidebar, captured offscreen.
///
/// Mounted in a borderless `NSWindow` at -20000/-20000 and captured with
/// `CGWindowListCreateImage` — the one route that rasterizes a SwiftUI `List` on a machine with no
/// display, per the project's headless-verification note. `.titled` is deliberately avoided: AppKit
/// drags such a window back onto a visible screen.
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

    /// The sidebar at its 220-point ideal, doubled by the backing scale of the capture.
    private static let sidebarPixels = 460

    private struct PixelDiff {
        var count: Int
        var minX: Int
        var maxX: Int
        var minY: Int
        var maxY: Int

        var box: String { "n=\(count) x=\(minX)...\(maxX) y=\(minY)...\(maxY)" }
    }

    @MainActor
    private final class Mount {
        let window: NSWindow
        let host: NSView

        init(db: AppDatabase, supervisor: StubSupervisor, router: NotificationRouter, ports: ListeningPortModel?) {
            host = NSHostingView(
                rootView: MainWindow().environment(
                    AppEnvironment(db: db, supervisor: supervisor, router: router, listeningPorts: ports)
                )
            )
            NSApplication.shared.setActivationPolicy(.accessory)
            window = NSWindow(
                contentRect: NSRect(x: -20_000, y: -20_000, width: 1100, height: 700),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.contentView = host
            window.orderBack(nil)
        }

        func close() { window.orderOut(nil) }

        func settle(turns: Int = 80) {
            for _ in 0..<turns {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                window.layoutIfNeeded()
                window.displayIfNeeded()
            }
        }

        func capture() throws -> NSBitmapImageRep {
            settle()
            let image = try XCTUnwrap(
                CGWindowListCreateImage(
                    .null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                    [.boundsIgnoreFraming, .bestResolution]
                ),
                "the window server produced no image for the offscreen window"
            )
            return NSBitmapImageRep(cgImage: image)
        }
    }

    private func diff(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> PixelDiff {
        var count = 0
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for y in 0..<min(a.pixelsHigh, b.pixelsHigh) {
            for x in 0..<min(Self.sidebarPixels, a.pixelsWide, b.pixelsWide) {
                guard let left = a.colorAt(x: x, y: y), let right = b.colorAt(x: x, y: y) else { continue }
                let apart = abs(left.redComponent - right.redComponent)
                    + abs(left.greenComponent - right.greenComponent)
                    + abs(left.blueComponent - right.blueComponent)
                guard apart > 0.02 else { continue }
                count += 1
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard count > 0 else { return PixelDiff(count: 0, minX: 0, maxX: 0, minY: 0, maxY: 0) }
        return PixelDiff(count: count, minX: minX, maxX: maxX, minY: minY, maxY: maxY)
    }

    /// A capture the window server has stopped changing.
    ///
    /// One `capture()` races the window server — the project's headless-verification note records
    /// `SidebarAttentionLiveTests` failing with the whole sidebar differing because a capture landed
    /// mid-relayout, and lists "capture twice and require two agreeing captures" as an untried fix.
    /// This is that fix: keep capturing until two consecutive images are pixel-identical, which is
    /// what makes every comparison below a statement about content rather than about timing.
    private func settled(
        _ mount: Mount, file: StaticString = #filePath, line: UInt = #line
    ) throws -> NSBitmapImageRep {
        var previous = try mount.capture()
        for _ in 0..<8 {
            let next = try mount.capture()
            if diff(previous, next).count == 0 { return next }
            previous = next
        }
        XCTFail("the window never stopped changing across 9 captures", file: file, line: line)
        return previous
    }

    /// Pumps the run loop until the window has selected something, rather than trusting a fixed
    /// settle: this machine runs several builds at once and a fixed turn count starves under load.
    private func waitForFocus(_ supervisor: StubSupervisor, _ mount: Mount, timeout: TimeInterval = 15) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, supervisor.focusedProjects.isEmpty {
            mount.settle(turns: 10)
        }
    }

    private func register(_ db: AppDatabase, _ name: String) throws -> Project {
        try ProjectStore(db).register(
            name: name, repoPath: "/tmp/ports-\(UUID().uuidString)", baseBranch: "main",
            worktreeRoot: "/tmp/ports-worktrees", memoryDir: nil
        )
    }

    @discardableResult
    private func session(
        _ db: AppDatabase, project: Project, id: String, title: String
    ) throws -> String {
        let task = try TaskStore(db).create(
            projectId: project.id, title: title, body: nil, acceptance: nil, priority: nil,
            column: .running, origin: .human, epicId: nil
        )
        try SessionStore(db).insert(
            AgentSession(
                sessionId: id, projectId: project.id, taskId: task.id, role: .worker,
                cwd: "/tmp", state: .running
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
    private func model(_ db: AppDatabase, _ rows: [ListeningPort]) throws -> ListeningPortModel {
        let model = ListeningPortModel(
            db: db,
            ledger: PIDSessionLedger(url: ledgerDir.appendingPathComponent("\(UUID().uuidString).json")),
            boardServerPort: { nil },
            shellConsolePIDs: { [:] },
            agentPIDs: { [:] },
            sweep: { _, _, _ in PortSweepResult(ports: rows, attributions: [:], liveIdentities: []) }
        )
        model.refresh()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, model.sweptAt == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(model.ports.count, rows.count, "the stub sweep never published its rows")
        return model
    }

    private func mount(_ db: AppDatabase, _ ports: ListeningPortModel?) -> Mount {
        Mount(db: db, supervisor: StubSupervisor(), router: NotificationRouter(), ports: ports)
    }

    /// The control every other assertion here rests on: nothing in this window moves on its own, so
    /// a pixel difference means the port list changed.
    func testTwoMountsOfTheSameSidebarWithTheSamePortsAreIdentical() throws {
        let db = try AppDatabase.inMemory()
        let alpha = try register(db, "Alpha")
        try session(db, project: alpha, id: "s-live", title: "Wire the thing")
        let rows = [
            ListeningPort(port: 3000, pid: 501, command: "node", sessionId: "s-live"),
            ListeningPort(port: 8080, pid: 502, command: "python3", sessionId: nil),
        ]

        let first = mount(db, try model(db, rows))
        let second = mount(db, try model(db, rows))
        defer { first.close(); second.close() }
        let left = try settled(first)
        let right = try settled(second)
        let drift = diff(left, right)
        XCTAssertEqual(drift.count, 0, "the ports panel must render deterministically (\(drift.box))")
    }

    /// One row per port, and every row above the Add Project button.
    ///
    /// Coordinate-free, because nothing in a SwiftUI sidebar is findable by name — `.help()` and
    /// the accessibility tree are both empty here. The footer is a bottom `safeAreaInset`, so it
    /// grows upward: a panel *above* Add Project leaves the button's pixels untouched when a row
    /// appears, which means the changed band never reaches below the band the empty panel occupies.
    /// A panel below the button would shove it and the change would run to the bottom of the
    /// sidebar.
    func testEachPortAddsARowAndEveryRowSitsAboveAddProject() throws {
        let db = try AppDatabase.inMemory()
        let alpha = try register(db, "Alpha")
        try session(db, project: alpha, id: "s-live", title: "Wire the thing")
        let one = [ListeningPort(port: 3000, pid: 501, command: "node", sessionId: "s-live")]
        let two = one + [ListeningPort(port: 8080, pid: 502, command: "python3", sessionId: nil)]

        let noPanel = mount(db, nil)
        let emptyMount = mount(db, try model(db, []))
        let oneMount = mount(db, try model(db, one))
        let twoMount = mount(db, try model(db, two))
        defer { noPanel.close(); emptyMount.close(); oneMount.close(); twoMount.close() }

        let empty = try settled(emptyMount)
        let one_ = try settled(oneMount)
        let headerBand = diff(try settled(noPanel), empty)
        let firstRow = diff(empty, one_)
        let secondRow = diff(one_, try settled(twoMount))

        XCTAssertGreaterThan(headerBand.count, 0, "the panel header must draw")
        XCTAssertGreaterThan(firstRow.count, 0, "one listening port must draw a row")
        XCTAssertGreaterThan(secondRow.count, 0, "a second listening port must draw a second row")

        // There is real footer below the panel — Add Project's padded row is ~38 points on its own.
        let belowPanel = empty.pixelsHigh - headerBand.maxY
        XCTAssertGreaterThan(
            belowPanel, Self.footerBelowPanelPixels,
            "the panel must not be the bottom of the sidebar (\(belowPanel) pixels below it)"
        )
        XCTAssertLessThanOrEqual(
            firstRow.maxY, headerBand.maxY,
            "a port row must grow upward from the panel, leaving Add Project where it was "
                + "(row \(firstRow.box), header \(headerBand.box))"
        )
        XCTAssertLessThanOrEqual(
            secondRow.maxY, headerBand.maxY,
            "the second row must stay above Add Project too "
                + "(row \(secondRow.box), header \(headerBand.box))"
        )
    }

    /// A floor, not a measurement: Add Project's padded row alone is about 38 points, and the
    /// notifications notice and usage footer sit below it. The assertion only needs to know that
    /// something substantial is drawn beneath the panel.
    private static let footerBelowPanelPixels = 50

    func testAnAttributedRowDoesNotRenderLikeAnOrphanedOne() throws {
        let db = try AppDatabase.inMemory()
        let alpha = try register(db, "Alpha")
        try session(db, project: alpha, id: "s-live", title: "Wire the thing")

        let attributed = mount(
            db, try model(db, [ListeningPort(port: 3000, pid: 501, command: "node", sessionId: "s-live")])
        )
        let orphaned = mount(
            db, try model(db, [ListeningPort(port: 3000, pid: 501, command: "node", sessionId: nil)])
        )
        defer { attributed.close(); orphaned.close() }

        XCTAssertGreaterThan(
            diff(try settled(attributed), try settled(orphaned)).count, 0,
            "a named owner and an orphan must not draw the same row"
        )
    }

    /// The empty state, as the report describes it: the header line and nothing else. The header
    /// still costs one line because it carries the refresh button — a panel that vanished entirely
    /// would leave nobody to ask about a port that appeared since the last hourly sweep.
    func testAnEmptyPanelCostsOneHeaderLineAndDrawsNoRows() throws {
        let db = try AppDatabase.inMemory()
        _ = try register(db, "Alpha")

        let withoutPanel = mount(db, nil)
        let emptyPanel = mount(db, try model(db, []))
        let onePort = mount(db, try model(db, [
            ListeningPort(port: 3000, pid: 501, command: "node", sessionId: nil)
        ]))
        defer { withoutPanel.close(); emptyPanel.close(); onePort.close() }

        let absent = try settled(withoutPanel)
        let empty = try settled(emptyPanel)
        let header = diff(absent, empty)
        let row = diff(empty, try settled(onePort))

        XCTAssertGreaterThan(header.count, 0, "the header line is drawn even with nothing listening")
        XCTAssertLessThan(
            header.maxY - header.minY, 60,
            "an empty panel is one line, not a box (\(header.box))"
        )
        XCTAssertGreaterThan(
            row.count, header.count,
            "a panel holding a port must paint more than an empty one"
        )
    }

    /// The end-to-end half of the routing: a port row's owner route, opened on a mounted window,
    /// selects its project through `MainWindow.select` — the same recorder
    /// `NotificationRoutingMountTests` reads for `focusChanged`.
    func testAnAttributedOwnerNameSelectsItsProject() throws {
        let db = try AppDatabase.inMemory()
        _ = try register(db, "Alpha")
        let beta = try register(db, "Beta")
        try session(db, project: beta, id: "s-beta", title: "Ship the panel")

        let ports = try model(db, [
            ListeningPort(port: 3000, pid: 501, command: "node", sessionId: "s-beta")
        ])
        let supervisor = StubSupervisor()
        let router = NotificationRouter()
        let mounted = Mount(db: db, supervisor: supervisor, router: router, ports: ports)
        defer { mounted.close() }
        mounted.settle()
        XCTAssertEqual(supervisor.focusedProjects, [], "nothing is selected before the click")

        let attributed = try XCTUnwrap(ports.ports.first)
        let route = try XCTUnwrap(portOwnerLabel(attributed).route, "an attributed row is a link")
        router.open(route)
        waitForFocus(supervisor, mounted)

        XCTAssertEqual(
            supervisor.focusedProjects.last, beta.id,
            "the owner name must select its project through MainWindow.select, not around it"
        )
        XCTAssertEqual(route.screen, .status, "a session's row opens the Status roster")
    }

    /// An orphan has no session to open, so its name is not a link and nothing happens.
    func testAnOrphansNameRoutesNowhere() throws {
        let db = try AppDatabase.inMemory()
        _ = try register(db, "Alpha")

        let ports = try model(db, [
            ListeningPort(port: 8080, pid: 502, command: "python3", sessionId: nil)
        ])
        let supervisor = StubSupervisor()
        let mounted = Mount(db: db, supervisor: supervisor, router: NotificationRouter(), ports: ports)
        defer { mounted.close() }
        mounted.settle()

        let orphan = try XCTUnwrap(ports.ports.first)
        XCTAssertEqual(orphan.ownership, .unattributed)
        XCTAssertNil(portOwnerLabel(orphan).route, "an orphan's name must not be a link")
        XCTAssertEqual(supervisor.focusedProjects, [], "and nothing may be selected on its behalf")
    }

}
