import AgentBoardCore
import AgentBoardRuntime
import AppKit
import SwiftUI
import XCTest
@testable import AgentBoard

/// The ports panel's height bound: never taller than twice the account-usage footer beneath it,
/// and no taller than its rows below that.
///
/// Heights are read off captures of the real sidebar: the panel's band is where a mount with the
/// panel differs from the same board without one. The footer is drawn from a fixture reading that
/// is two hours old, so its age line says the same thing in every mount of a test.
@MainActor
final class PortsPanelCeilingTests: XCTestCase {
    private var scratch: URL!
    private var collapse = IsolatedCollapseState()

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentboard-portsceiling/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        collapse = IsolatedCollapseState()
    }

    override func tearDown() {
        collapse.remove()
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    /// The sidebar's ideal width, less a strip at its trailing edge where a legacy scroller's knob
    /// would change size with the row count.
    private static let sidebarPoints = 0..<196

    private func usageModel() throws -> AccountUsageModel {
        let url = scratch.appendingPathComponent("\(UUID().uuidString).json")
        let fetched = Int64(Date.now.timeIntervalSince1970 * 1000) - 2 * 3_600_000
        try """
        {"cachedUsageUtilization": {"fetchedAtMs": \(fetched), "utilization": {
          "five_hour": {"utilization": 3, "resets_at": "2026-09-12T18:40:00.263555+00:00"},
          "seven_day": {"utilization": 23, "resets_at": "2026-09-14T21:00:00.263579+00:00"}}}}
        """.write(to: url, atomically: true, encoding: .utf8)
        let model = AccountUsageModel(configURL: url, refresher: AccountUsageRefresher { _ in false })
        let reading = _Concurrency.Task { await model.run() }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, model.snapshot == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        reading.cancel()
        XCTAssertNotNil(model.snapshot, "the fixture reading was never loaded")
        return model
    }

    private func portsModel(_ db: AppDatabase, _ rows: [ListeningPort]) throws -> ListeningPortModel {
        let model = ListeningPortModel(
            db: db,
            ledger: PIDSessionLedger(url: scratch.appendingPathComponent("\(UUID().uuidString)-ledger.json")),
            boardServerPort: { nil },
            shellConsolePIDs: { [:] },
            agentPIDs: { [:] },
            sweep: { _, _, _ in PortSweepResult(ports: rows, attributions: [:], liveIdentities: []) },
            stopper: { _, pid, _, _ in PortStopReport(scope: .processGroup(pid), escalated: true, outcome: .stopped) }
        )
        model.refresh()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, model.sweptAt == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(model.ports.count, rows.count, "the stub sweep never published its rows")
        return model
    }

    private func board() throws -> (AppDatabase, Project) {
        let db = try AppDatabase.inMemory()
        let project = try ProjectStore(db).register(
            name: "Alpha", repoPath: "/tmp/ports-\(UUID().uuidString)", baseBranch: "main",
            worktreeRoot: "/tmp/ports-worktrees", memoryDir: nil
        )
        return (db, project)
    }

    private func rows(_ count: Int, for project: Project, from first: Int = 3000) -> [ListeningPort] {
        let owner = PortOwnerKey.shellConsole(projectId: project.id).encoded
        return (0..<count).map { ListeningPort(port: first + $0, pid: Int32(600 + $0), command: "node", sessionId: owner) }
    }

    private func sidebar(_ db: AppDatabase, ports: ListeningPortModel?, usage: AccountUsageModel) -> OffscreenMount {
        OffscreenMount(
            MainWindow(collapseState: collapse.state).environment(
                AppEnvironment(db: db, supervisor: StubSupervisor(), accountUsage: usage, listeningPorts: ports)
            )
        )
    }

    private func capture(_ mount: OffscreenMount) throws -> Capture {
        try mount.capture(points: Self.sidebarPoints, showing: SidebarContent(rows: 3, headers: 1))
    }

    /// The panel's painted band, in points, as the difference between a sidebar with it and without.
    private func band(_ with: Capture, _ without: Capture) -> (top: CGFloat, height: CGFloat) {
        let box = with.diff(without, columns: with.columns(Self.sidebarPoints))
        let scale = CGFloat(with.width) / with.windowWidth
        return (CGFloat(box.minY) / scale, CGFloat(box.height) / scale)
    }

    /// The footer as the sidebar draws it, measured on its own at the sidebar's ideal width.
    private func footerHeight(_ usage: AccountUsageModel) -> CGFloat {
        let host = NSHostingView(rootView: AccountUsageFooter(model: usage).frame(width: 220))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    func testTheFullFooterMeasuresWhatTheFallbackCeilingAssumes() throws {
        let measured = footerHeight(try usageModel())
        print("AccountUsageFooter measured height: \(measured)pt; ceiling \(2 * measured)pt")
        XCTAssertEqual(
            measured, AccountUsageFooter.fullHeight, accuracy: 0.5,
            "AccountUsageFooter.fullHeight no longer matches the footer it stands in for"
        )
        XCTAssertEqual(PortsPanel.ceiling(footerHeight: 0), 2 * AccountUsageFooter.fullHeight)
        XCTAssertEqual(PortsPanel.ceiling(footerHeight: 80), 160)
    }

    /// Thirty rows is several times what fits. The panel stops at the ceiling, and the header stays
    /// at its top: a thirty-first row changes nothing but the header's count, because the row lands
    /// below the fold and is not painted anywhere.
    func testMorePortsThanFitStopAtTwiceTheFooterWithTheHeaderStillDrawn() throws {
        let (db, alpha) = try board()
        let usage = try usageModel()
        let ceiling = PortsPanel.ceiling(footerHeight: footerHeight(usage))

        let without = sidebar(db, ports: nil, usage: usage)
        let thirty = sidebar(db, ports: try portsModel(db, rows(30, for: alpha)), usage: usage)
        let thirtyOne = sidebar(
            db, ports: try portsModel(db, rows(30, for: alpha) + rows(1, for: alpha, from: 9000)), usage: usage
        )
        defer { without.close(); thirty.close(); thirtyOne.close() }

        let absent = try capture(without)
        let full = try capture(thirty)
        let panel = band(full, absent)
        print("30-row panel band: \(panel.height)pt against a \(ceiling)pt ceiling")

        XCTAssertLessThanOrEqual(panel.height, ceiling, "the panel outgrew twice the footer's height")
        XCTAssertGreaterThan(
            panel.height, ceiling - 20,
            "thirty rows must fill the panel to its ceiling, not stop short of it"
        )

        let extra = full.diff(try capture(thirtyOne), columns: full.columns(Self.sidebarPoints))
        let scale = CGFloat(full.width) / full.windowWidth
        XCTAssertGreaterThan(extra.count, 0, "the header's count must change from 30 to 31")
        XCTAssertLessThanOrEqual(
            CGFloat(extra.maxY) / scale - panel.top, 16,
            "a row past the fold changed pixels below the header line — it was painted, or the header moved"
        )
    }

    /// Below the ceiling the panel is as tall as its rows: two rows do not reserve the bound.
    func testOneOrTwoRowsSizeToTheirContentBelowTheCeiling() throws {
        let (db, alpha) = try board()
        let usage = try usageModel()
        let ceiling = PortsPanel.ceiling(footerHeight: footerHeight(usage))

        let without = sidebar(db, ports: nil, usage: usage)
        let one = sidebar(db, ports: try portsModel(db, rows(1, for: alpha)), usage: usage)
        let two = sidebar(db, ports: try portsModel(db, rows(2, for: alpha)), usage: usage)
        defer { without.close(); one.close(); two.close() }

        let absent = try capture(without)
        let oneBand = band(try capture(one), absent)
        let twoBand = band(try capture(two), absent)
        print("1-row panel band: \(oneBand.height)pt, 2-row: \(twoBand.height)pt, ceiling \(ceiling)pt")

        XCTAssertGreaterThan(twoBand.height, oneBand.height + 10, "a second row must add its own height")
        XCTAssertLessThan(twoBand.height, ceiling / 2, "two rows reserved space they do not fill")
    }

    /// Collapsed is the header line whatever the panel holds — the same height as the empty panel.
    func testACollapsedPanelIsOneHeaderLineHoweverManyPortsItHolds() throws {
        let (db, alpha) = try board()
        let key = "\(PortsPanel.expandedKey).test-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }

        func height(_ ports: ListeningPortModel, expanded: Bool) -> CGFloat {
            UserDefaults.standard.set(expanded, forKey: key)
            let mount = OffscreenMount(
                PortsPanel(ceiling: 220, expandedKey: key)
                    .frame(width: 220)
                    .environment(AppEnvironment(db: db, supervisor: StubSupervisor(), listeningPorts: ports)),
                size: CGSize(width: 220, height: 700)
            )
            defer { mount.close() }
            for _ in 0..<40 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                mount.window.layoutIfNeeded()
            }
            return mount.host.fittingSize.height
        }

        let many = try portsModel(db, rows(30, for: alpha))
        let collapsed = height(many, expanded: false)
        let empty = height(try portsModel(db, []), expanded: true)
        let expanded = height(many, expanded: true)

        XCTAssertEqual(collapsed, empty, accuracy: 0.5, "collapsed must cost the empty panel's one line")
        XCTAssertGreaterThan(expanded, collapsed + 100, "expanding thirty rows must draw them")
        XCTAssertLessThanOrEqual(expanded, 220, "the ceiling holds without a window proposing a height too")
    }
}
