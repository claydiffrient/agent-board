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

/// The Status pane's ports section, captured offscreen through the project's shared
/// `OffscreenMount`/`Capture` infrastructure (`OffscreenCapture.swift`). Synchronous throughout, for
/// the reason `PortsPanelLiveTests` records: pumping the run loop from inside an `async` test body
/// does not flush SwiftUI.
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

    private func describe(_ box: PixelDiff) -> String { "n=\(box.count) y=\(box.minY)...\(box.maxY)" }

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

    private func pane(_ db: AppDatabase, _ project: Project, _ ports: ListeningPortModel) -> OffscreenMount {
        OffscreenMount(
            StatusView(project: project).environment(
                AppEnvironment(
                    db: db, supervisor: StubSupervisor(), router: NotificationRouter(),
                    listeningPorts: ports
                )
            ),
            size: CGSize(width: 900, height: 600)
        )
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

        let base = pane(db, mine, mineModel)
        let withForeign = pane(db, mine, theirsModel)
        let withSecond = pane(db, mine, secondModel)
        defer { base.close(); withForeign.close(); withSecond.close() }

        let baseline = try base.capture()
        let foreign = baseline.diff(try withForeign.capture(), columns: 0..<baseline.width)
        let second = baseline.diff(try withSecond.capture(), columns: 0..<baseline.width)

        XCTAssertEqual(
            foreign.count, 0,
            "another project's port drew on this project's Status pane (\(describe(foreign)))"
        )
        XCTAssertGreaterThan(
            second.count, 0,
            "a second port belonging to this project drew no row"
        )
    }

    /// The Status pane reads `ports(inProject:)` and starts nothing of its own: mounting it sweeps
    /// zero times beyond the model's own first refresh, and neither does typing a query (SPEC §10).
    func testTheStatusPaneStartsNoSweepOnMountOrQuery() throws {
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

        let pane = OffscreenMount(
            StatusView(project: mine).environment(env), size: CGSize(width: 900, height: 500)
        )
        defer { pane.close() }
        // A long, fixed dwell rather than a settle poll: an extra sweep hops through a detached
        // `.utility`-priority task (`ListeningPortModel.swift:204-231`), which a busy machine can
        // delay well past a short pump even though nothing it draws changes a pixel `capture()`
        // could settle on.
        pumpBriefly(pane.window, turns: 150)
        XCTAssertEqual(counter.count, 1, "mounting the Status pane swept the process table on its own")

        let unsearched = try pane.capture()
        type("nothing matches", into: pane)
        let searched = try pane.capture()
        pumpBriefly(pane.window, turns: 150)
        XCTAssertGreaterThan(unsearched.diff(searched, columns: 0..<unsearched.width).count, 0,
                             "the query must have hidden the port row, or the count below measured nothing")
        XCTAssertEqual(counter.count, 1, "a query in the Status pane swept the process table")
    }

    private func type(_ text: String, into mount: OffscreenMount) {
        var queue: [NSView] = [mount.host]
        var fields: [NSTextField] = []
        while let view = queue.popLast() {
            if let field = view as? NSTextField, field.isEditable { fields.append(field) }
            queue.append(contentsOf: view.subviews)
        }
        guard fields.count == 1, let field = fields.first else {
            return XCTFail("expected the Status pane's search field alone, found \(fields.count) editable fields")
        }
        field.stringValue = text
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
    }
}
