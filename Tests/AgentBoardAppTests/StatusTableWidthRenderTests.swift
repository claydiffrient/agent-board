import AgentBoardCore
import AppKit
import SwiftUI
import XCTest
@testable import AgentBoard

/// The Status session table at the minimum detail width (SPEC §10.1). SwiftUI's `Table` mounts as
/// an `NSTableView` whose header cells carry the column titles, so the geometry is read from AppKit.
@MainActor
final class StatusTableWidthRenderTests: XCTestCase {
    func testAtTheMinimumDetailWidthTheActionsColumnIsOnScreenWithoutScrollingSideways() throws {
        let db = try AppDatabase.inMemory()
        let project = try ProjectStore(db).register(
            name: "derivita-ui", repoPath: "/tmp/status-width-\(UUID().uuidString)", baseBranch: "main",
            worktreeRoot: "/tmp/status-width-worktrees", memoryDir: nil
        )
        // Stopped, so every row carries Resume, the widest action; enough rows to need a vertical scroller.
        let endedAt = Int64.nowMillis - 60_000
        for index in 0..<16 {
            let task = try TaskStore(db).create(
                projectId: project.id, title: "Task number \(index) with a long title", body: nil, acceptance: nil,
                priority: nil, column: .running, origin: .human, epicId: nil, type: nil
            )
            try SessionStore(db).insert(AgentSession(
                sessionId: String(format: "s%07d", index), projectId: project.id, taskId: task.id, role: .worker,
                cwd: "/tmp", state: .stopped, startedAt: endedAt - 3_600_000, endedAt: endedAt,
                lastActivity: endedAt, tokensIn: 123_456, tokensOut: 7_890, cacheRead: 4_560_000,
                estCostUSD: 12.3456, lastTool: "mcp__agent-board__report_complete"
            ))
        }

        let mount = OffscreenMount(
            StatusView(project: project).environment(renderEnvironment(db: db)),
            size: CGSize(width: MainWindowLayout.minimumDetailWidth, height: 548)
        )
        defer { mount.close() }
        _ = try mount.capture()

        let table = try XCTUnwrap(tables(in: mount.host).first, "the session table never mounted")
        XCTAssertEqual(table.numberOfRows, 16)
        let visible = try XCTUnwrap(table.enclosingScrollView).contentView.bounds
        XCTAssertLessThanOrEqual(table.bounds.width, visible.width + 0.5, "the table scrolls sideways")
        let titles = table.tableColumns.map(\.headerCell.stringValue)
        let actions = try XCTUnwrap(titles.firstIndex(of: "Actions"), "columns: \(titles)")
        XCTAssertLessThanOrEqual(
            table.rect(ofColumn: actions).maxX, visible.maxX + 0.5,
            "Actions starts or ends out of view: \(zip(titles, table.tableColumns.indices.map(table.rect(ofColumn:))).map { "\($0) \($1)" })"
        )
    }

    func testTheSpendTooltipCarriesTheTokenDetailTheCellNoLongerDraws() {
        let session = AgentSession(
            sessionId: "s1", projectId: "p", role: .worker, cwd: "/tmp",
            tokensIn: 123_456, tokensOut: 7_890, cacheRead: 4_560_000, estCostUSD: 12.3456
        )
        XCTAssertEqual(StatusCell.spend(session, cap: 1_000_000), "$12.3456 · 131.3k / 1.00M · 4.56M cached")
        XCTAssertEqual(StatusCell.spend(session, cap: nil), "$12.3456 · 131.3k · 4.56M cached")
    }

    private func tables(in root: NSView) -> [NSTableView] {
        var found: [NSTableView] = []
        var queue = [root]
        while let view = queue.popLast() {
            if let table = view as? NSTableView { found.append(table) }
            queue.append(contentsOf: view.subviews)
        }
        return found
    }
}
