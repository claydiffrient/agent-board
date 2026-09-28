import AgentBoardCore
import AgentBoardRuntime
import AppKit
import SwiftUI
import XCTest
@testable import AgentBoard

/// `MainWindow` at its minimum size (SPEC §10.1), with the sidebar's bottom stack as tall as it gets
/// on this machine: a Ports panel with more rows than fit, and a usage footer with both windows.
///
/// Frames come from the AppKit views SwiftUI builds, in window coordinates (origin bottom-left).
/// The stack's top edge is the list scroll view's bottom plus its bottom content inset, which covers
/// both layouts: a list that ends where the stack starts, and a list under a bottom `safeAreaInset`
/// that reports the stack's height as that inset while still painting rows beneath it.
@MainActor
final class MainWindowMinimumSizeTests: XCTestCase {
    private var scratch: URL!
    private var collapse = IsolatedCollapseState()

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentboard-minsize/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        collapse = IsolatedCollapseState()
    }

    override func tearDown() {
        collapse.remove()
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    func testTheWindowCannotBeMadeSmallerThanTheDocumentedMinimum() throws {
        let mount = OffscreenMount(
            MainWindow(collapseState: collapse.state).environment(renderEnvironment(db: try AppDatabase.inMemory())),
            size: MainWindowLayout.minimumSize
        )
        defer { mount.close() }
        _ = try mount.capture()
        XCTAssertEqual(mount.window.contentMinSize, MainWindowLayout.minimumSize)
    }

    func testAtTheMinimumSizeTheBottomStackDrawsOverNoVisibleSidebarRow() throws {
        let db = try AppDatabase.inMemory()
        let workspaces = try ["Personal", "Work"].map { try WorkspaceStore(db).create(name: $0) }
        let projects = try (0..<14).map { index in
            let project = try ProjectStore(db).register(
                name: "project-\(index)", repoPath: "/tmp/minsize-\(UUID().uuidString)", baseBranch: "main",
                worktreeRoot: "/tmp/minsize-worktrees", memoryDir: nil
            )
            try WorkspaceStore(db).assign(projectId: project.id, workspaceId: workspaces[index % 2].id)
            return project
        }
        let owner = PortOwnerKey.shellConsole(projectId: projects[0].id).encoded
        let ports = try portsModel(db, (0..<30).map {
            ListeningPort(port: 3000 + $0, pid: Int32(600 + $0), command: "node", sessionId: owner)
        })
        let mount = OffscreenMount(
            MainWindow(collapseState: collapse.state).environment(
                AppEnvironment(db: db, supervisor: StubSupervisor(), accountUsage: try usageModel(), listeningPorts: ports)
            ),
            size: MainWindowLayout.minimumSize
        )
        defer { mount.close() }
        _ = try mount.capture(points: 0..<Int(MainWindowLayout.sidebarIdealWidth)) { _ in
            self.sidebar(in: mount).map { $0.footerBars == 2 && $0.portRows != nil } ?? false
        }
        let sidebar = try XCTUnwrap(self.sidebar(in: mount), "the sidebar list never mounted")

        let stack = CGRect(x: 0, y: 0, width: MainWindowLayout.sidebarIdealWidth, height: sidebar.stackTop)
        for piece in [sidebar.portRows, sidebar.workspaceMenu].compactMap({ $0 }) + sidebar.bars {
            XCTAssertLessThanOrEqual(piece.maxY, stack.maxY + 0.5, "\(piece) is part of the stack but sits above \(stack)")
        }
        XCTAssertGreaterThan(sidebar.documentHeight, sidebar.unobstructed.height, "the fixture must be long enough to scroll")
        XCTAssertGreaterThanOrEqual(
            sidebar.unobstructed.height, MainWindowLayout.sidebarListReserve - 0.5,
            "the list must keep its reserve of rows clear of the stack"
        )

        let overlapping = sidebar.rows
            .map { $0.intersection(sidebar.painted) }
            .filter { !$0.isNull && $0.height > 0.5 && $0.intersection(stack).height > 0.5 }
        XCTAssertEqual(
            overlapping, [],
            "rows the list paints under the bottom stack (stack \(stack), list clip \(sidebar.painted))"
        )
    }

    private struct SidebarFrames {
        /// The clip view: every row inside it is drawn, whether or not a content inset covers it.
        var painted: CGRect
        var unobstructed: CGRect
        var documentHeight: CGFloat
        var stackTop: CGFloat
        var rows: [CGRect]
        var bars: [CGRect]
        var workspaceMenu: CGRect?
        var portRows: CGRect?
        var footerBars: Int { bars.count }
    }

    private func sidebar(in mount: OffscreenMount) -> SidebarFrames? {
        var list: NSScrollView?
        var rows: [CGRect] = []
        var bars: [CGRect] = []
        var menu: CGRect?
        var portRows: CGRect?
        var queue: [NSView] = [mount.host]
        while let view = queue.popLast() {
            let name = String(describing: type(of: view))
            let frame = view.convert(view.bounds, to: nil)
            let inSidebar = frame.maxX <= MainWindowLayout.sidebarIdealWidth + 0.5
            switch name {
            case "ListCoreScrollView" where inSidebar: list = view as? NSScrollView
            case "ListTableCellView" where inSidebar, "ListTableHeaderView" where inSidebar: rows.append(frame)
            case "SwiftUIPopupButton" where inSidebar: menu = frame
            case "HostingScrollView" where inSidebar: portRows = frame
            default: if view is NSProgressIndicator, inSidebar { bars.append(frame) }
            }
            queue.append(contentsOf: view.subviews)
        }
        guard let list, let document = list.documentView else { return nil }
        let clipFrame = list.contentView.convert(list.contentView.bounds, to: nil)
        let insets = list.contentInsets
        let unobstructed = CGRect(
            x: clipFrame.minX, y: clipFrame.minY + insets.bottom,
            width: clipFrame.width, height: clipFrame.height - insets.bottom - insets.top
        )
        return SidebarFrames(
            painted: clipFrame, unobstructed: unobstructed, documentHeight: document.frame.height,
            stackTop: list.convert(list.bounds, to: nil).minY + insets.bottom,
            rows: rows, bars: bars, workspaceMenu: menu, portRows: portRows
        )
    }

    private func usageModel() throws -> AccountUsageModel {
        let url = scratch.appendingPathComponent("usage.json")
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
            ledger: PIDSessionLedger(url: scratch.appendingPathComponent("ledger.json")),
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
}
