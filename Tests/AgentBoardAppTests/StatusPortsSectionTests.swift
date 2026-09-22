import AgentBoardCore
import AgentBoardRuntime
import AppKit
import Darwin
import Foundation
import SwiftUI
import XCTest
@testable import AgentBoard

/// Counts sweeps, so "did mounting the second surface start a second sweep" is answered by a number.
private final class CountingSweep: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let rows: [ListeningPort]

    init(rows: [ListeningPort]) { self.rows = rows }

    var count: Int { lock.withLock { calls } }

    func sweep(_ owners: [pid_t: String], _ remembered: [PIDIdentity: String], _ port: Int?) -> PortSweepResult {
        lock.withLock { calls += 1 }
        return PortSweepResult(ports: rows, attributions: [:], liveIdentities: [])
    }
}

/// The Status pane's ports section, captured offscreen.
///
/// Mounted in a borderless `NSWindow` at -20000/-20000 and captured with `CGWindowListCreateImage`,
/// per the project's headless-verification note; `settled` requires two consecutive identical
/// captures so every comparison is a statement about content rather than about timing. Synchronous
/// throughout, for the reason `PortsPanelLiveTests` records: pumping the run loop from inside an
/// `async` test body does not flush SwiftUI.
///
/// Every session used here ended over an hour ago, so the roster table is its "No Live Sessions"
/// placeholder and nothing above the section redraws on a clock.
@MainActor
final class StatusPortsSectionLiveTests: XCTestCase {
    private var ledgerDir: URL!

    override func setUpWithError() throws {
        ledgerDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentboard-statusports/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ledgerDir, withIntermediateDirectories: true)
        UserDefaults.standard.set(true, forKey: PortsPanel.expandedKey)
        UserDefaults.standard.set(false, forKey: "status.showEndedSessions")
        SidebarCollapseState.standard.save([])
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: PortsPanel.expandedKey)
        UserDefaults.standard.removeObject(forKey: "status.showEndedSessions")
        UserDefaults.standard.removeObject(forKey: SidebarCollapseState.key)
        try? FileManager.default.removeItem(at: ledgerDir)
        super.tearDown()
    }

    private struct PixelDiff {
        var count: Int
        var minY: Int
        var maxY: Int

        var box: String { "n=\(count) y=\(minY)...\(maxY)" }
    }

    @MainActor
    private final class Mount {
        let window: NSWindow

        init<Root: View>(_ root: Root, width: CGFloat = 900, height: CGFloat = 600) {
            NSApplication.shared.setActivationPolicy(.accessory)
            window = NSWindow(
                contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: height),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.contentView = NSHostingView(rootView: root)
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
        var minY = Int.max, maxY = -1
        for y in 0..<min(a.pixelsHigh, b.pixelsHigh) {
            for x in 0..<min(a.pixelsWide, b.pixelsWide) {
                guard let left = a.colorAt(x: x, y: y), let right = b.colorAt(x: x, y: y) else { continue }
                let apart = abs(left.redComponent - right.redComponent)
                    + abs(left.greenComponent - right.greenComponent)
                    + abs(left.blueComponent - right.blueComponent)
                guard apart > 0.02 else { continue }
                count += 1
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard count > 0 else { return PixelDiff(count: 0, minY: 0, maxY: 0) }
        return PixelDiff(count: count, minY: minY, maxY: maxY)
    }

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

    private func register(_ db: AppDatabase, _ name: String) throws -> Project {
        try ProjectStore(db).register(
            name: name, repoPath: "/tmp/status-ports-\(UUID().uuidString)", baseBranch: "main",
            worktreeRoot: "/tmp/status-ports-worktrees", memoryDir: nil
        )
    }

    /// A session that ended two hours ago: past `SessionVisibility.endedGrace`, so the roster table
    /// shows its placeholder and holds still, while `agent_session` and `task` keep naming the port.
    @discardableResult
    private func endedSession(
        _ db: AppDatabase, project: Project, id: String, title: String
    ) throws -> String {
        let task = try TaskStore(db).create(
            projectId: project.id, title: title, body: nil, acceptance: nil, priority: nil,
            column: .done, origin: .human, epicId: nil
        )
        try SessionStore(db).insert(
            AgentSession(
                sessionId: id, projectId: project.id, taskId: task.id, role: .worker,
                cwd: "/tmp", state: .completed,
                endedAt: Int64.nowMillis - 2 * 60 * 60 * 1000
            )
        )
        return id
    }

    private func model(
        _ db: AppDatabase, _ rows: [ListeningPort], publishes: Int? = nil, sweep: CountingSweep? = nil
    ) throws -> ListeningPortModel {
        let counter = sweep ?? CountingSweep(rows: rows)
        let model = ListeningPortModel(
            db: db,
            ledger: PIDSessionLedger(url: ledgerDir.appendingPathComponent("\(UUID().uuidString).json")),
            boardServerPort: { nil },
            shellConsolePIDs: { [:] },
            agentPIDs: { [:] },
            sweep: { owners, remembered, port in counter.sweep(owners, remembered, port) },
            stopper: { _, pid, _, _ in
                PortStopReport(scope: .processGroup(pid), escalated: true, outcome: .stopped)
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

    private func pane(_ db: AppDatabase, _ project: Project, _ ports: ListeningPortModel) -> Mount {
        Mount(
            StatusView(project: project).environment(
                AppEnvironment(
                    db: db, supervisor: StubSupervisor(), router: NotificationRouter(),
                    listeningPorts: ports
                )
            )
        )
    }

    /// The control every other assertion here rests on: two mounts of the same pane over the same
    /// ports are pixel-identical, so a difference below means the port list changed.
    func testTwoMountsOfTheSameStatusPaneWithTheSamePortsAreIdentical() throws {
        let db = try AppDatabase.inMemory()
        let mine = try register(db, "Mine")
        try endedSession(db, project: mine, id: "s-mine", title: "Run the dev server")
        let rows = [ListeningPort(port: 3000, pid: 501, command: "node", sessionId: "s-mine", source: .ledger)]

        let first = pane(db, mine, try model(db, rows))
        let second = pane(db, mine, try model(db, rows))
        defer { first.close(); second.close() }

        let drift = diff(try settled(first), try settled(second))
        XCTAssertEqual(drift.count, 0, "the Status pane must render deterministically (\(drift.box))")
    }

    /// The pane draws this project's ports and nothing else: adding another project's port to the
    /// same sweep changes no pixel, while adding one of this project's does.
    func testTheStatusPaneDrawsThisProjectsPortsAndNotAnotherProjects() throws {
        let db = try AppDatabase.inMemory()
        let mine = try register(db, "Mine")
        let theirs = try register(db, "Theirs")
        try endedSession(db, project: mine, id: "s-mine", title: "Run the dev server")
        try endedSession(db, project: theirs, id: "s-theirs", title: "Something else")

        let onlyMine = [ListeningPort(port: 3000, pid: 501, command: "node", sessionId: "s-mine", source: .ledger)]
        let plusTheirs = onlyMine + [
            ListeningPort(port: 4000, pid: 502, command: "vite", sessionId: "s-theirs", source: .ledger)
        ]
        let plusMine = onlyMine + [
            ListeningPort(port: 5173, pid: 503, command: "vite", sessionId: "s-mine", source: .ledger)
        ]

        let mineModel = try model(db, onlyMine)
        let theirsModel = try model(db, plusTheirs)
        let secondModel = try model(db, plusMine)
        XCTAssertEqual(theirsModel.ports.count, 2, "the foreign port must be in the sweep to be excluded from the pane")
        XCTAssertEqual(theirsModel.ports(inProject: mine.id).map(\.port), [3000])

        let base = pane(db, mine, mineModel)
        let withForeign = pane(db, mine, theirsModel)
        let withSecond = pane(db, mine, secondModel)
        defer { base.close(); withForeign.close(); withSecond.close() }

        let baseline = try settled(base)
        let foreign = diff(baseline, try settled(withForeign))
        let second = diff(baseline, try settled(withSecond))

        XCTAssertEqual(
            foreign.count, 0,
            "another project's port drew on this project's Status pane (\(foreign.box))"
        )
        XCTAssertGreaterThan(
            second.count, 0,
            "a second port belonging to this project drew no row"
        )
    }

    /// The row this epic exists for, on the per-project pane. The session ended two hours ago and
    /// the socket did not; `agent_session` and `task` still name its project, so the row belongs to
    /// a project and the pane is where a human finds it.
    func testAnOrphanWhoseEndedSessionStillNamesThisProjectIsDrawnHere() throws {
        let db = try AppDatabase.inMemory()
        let mine = try register(db, "Mine")
        try endedSession(db, project: mine, id: "s-ended", title: "Ship the dev server")

        let ports = try model(db, [
            ListeningPort(port: 3000, pid: 501, command: "node", sessionId: "s-ended", source: .ledger)
        ])
        let row = try XCTUnwrap(ports.ports.first)
        XCTAssertEqual(row.ownership, .orphaned, "a ledger-sourced row is the ended session's")
        XCTAssertEqual(ports.ports(inProject: mine.id).map(\.port), [3000])

        let empty = pane(db, mine, try model(db, []))
        let orphaned = pane(db, mine, ports)
        defer { empty.close(); orphaned.close() }

        XCTAssertGreaterThan(
            diff(try settled(empty), try settled(orphaned)).count, 0,
            "an orphan whose ended session names this project must draw a row on its pane"
        )
    }

    /// A port nothing names is not drawn anywhere, so it cannot land on a project's pane either.
    func testAPortNothingNamesDrawsNothingOnAnyProjectsPane() throws {
        let db = try AppDatabase.inMemory()
        let mine = try register(db, "Mine")
        try endedSession(db, project: mine, id: "s-mine", title: "Run the dev server")
        let mineOnly = [ListeningPort(port: 3000, pid: 501, command: "node", sessionId: "s-mine", source: .ledger)]

        let unnamed = try model(db, mineOnly + [
            ListeningPort(port: 8080, pid: 502, command: "python3", sessionId: nil)
        ], publishes: 1)
        XCTAssertEqual(unnamed.ports.map(\.port), [3000])
        XCTAssertEqual(unnamed.ports(inProject: mine.id).map(\.port), [3000])

        let base = pane(db, mine, try model(db, mineOnly))
        let withUnnamed = pane(db, mine, unnamed)
        defer { base.close(); withUnnamed.close() }

        let drift = diff(try settled(base), try settled(withUnnamed))
        XCTAssertEqual(
            drift.count, 0,
            "a port nothing names drew on a project's Status pane (\(drift.box))"
        )
    }

    /// One sweep, two surfaces. The Status pane reads `ports(inProject:)` and starts nothing of its
    /// own: mounted alone it sweeps zero times, and mounted beside the sidebar panel the pair costs
    /// exactly the panel's one mount refresh.
    func testMountingBothSurfacesDoesNotDoubleTheSweepCount() throws {
        let db = try AppDatabase.inMemory()
        let mine = try register(db, "Mine")
        try endedSession(db, project: mine, id: "s-mine", title: "Run the dev server")
        let rows = [ListeningPort(port: 3000, pid: 501, command: "node", sessionId: "s-mine", source: .ledger)]

        let counter = CountingSweep(rows: rows)
        let ports = try model(db, rows, sweep: counter)
        XCTAssertEqual(counter.count, 1, "the model's own first refresh")

        let env = AppEnvironment(
            db: db, supervisor: StubSupervisor(), router: NotificationRouter(), listeningPorts: ports
        )

        let paneOnly = Mount(StatusView(project: mine).environment(env), width: 900, height: 500)
        defer { paneOnly.close() }
        paneOnly.settle()
        XCTAssertEqual(counter.count, 1, "the Status pane swept the process table on its own")

        let both = Mount(
            VStack(spacing: 0) {
                PortsPanel()
                StatusView(project: mine)
            }.environment(env),
            width: 900, height: 700
        )
        defer { both.close() }
        both.settle()

        XCTAssertEqual(
            counter.count, 2,
            "two surfaces must cost the sidebar panel's one mount refresh and nothing more"
        )
        XCTAssertEqual(
            ports.ports(inProject: mine.id).map(\.port), [3000],
            "and the pane is reading real rows, so the counts above are not vacuous"
        )

        ports.refresh()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, counter.count == 2 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(
            counter.count, 3,
            "the counter does not count sweeps, so nothing above was measured"
        )
    }
}
