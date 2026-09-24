import AgentBoardCore
import AgentBoardRuntime
import AppKit
import SwiftUI
import XCTest
@testable import AgentBoard

/// Which rows the Status pane draws for a query, proved by pixels, the way
/// `TaskBoardSearchRenderTests` proves cards: SwiftUI `Text` leaves no string in the view tree.
///
/// Each board holds two sessions, `s-idle` and `s-other`, and the two boards of a pair differ only in
/// `s-other`'s state and in the command of the port it holds, neither of which any query here
/// matches. So two searched boards that differ in zero pixels below the search bar prove neither
/// draws `s-other`'s row or its port, and the footer's session count is the same on both. The state
/// rather than the task title: titles arrive on a second observation, and a capture that settles
/// before it lands draws "—" on both boards and compares equal. Every zero is paired with a
/// comparison that must differ.
///
/// Every session ended a minute ago: inside `SessionVisibility.endedGrace`, so the rows are drawn,
/// and ended, so the Elapsed column's clock repaints the same text.
@MainActor
final class StatusSearchRenderTests: XCTestCase {
    private var mounts: [OffscreenMount] = []
    private var ledgerDir: URL!

    override func setUpWithError() throws {
        ledgerDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentboard-statussearch/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ledgerDir, withIntermediateDirectories: true)
        UserDefaults.standard.set(false, forKey: "status.showEndedSessions")
    }

    override func tearDown() {
        mounts.forEach { $0.close() }
        mounts = []
        UserDefaults.standard.removeObject(forKey: "status.showEndedSessions")
        try? FileManager.default.removeItem(at: ledgerDir)
        super.tearDown()
    }

    private static let idle = "Idle cap watchdog"

    func testTwoMountsOfTheSameSearchedPaneAreIdentical() throws {
        let first = try mount(variant: .first, ports: true, query: "idle cap")
        let second = try mount(variant: .first, ports: true, query: "idle cap")
        XCTAssertEqual(first.capture.diff(second.capture, columns: 0..<first.capture.width).count, 0)
    }

    func testAQueryNarrowsTheRosterAndANonMatchingSessionIsAbsent() throws {
        let searched = try mount(variant: .first, query: "idle cap")
        XCTAssertEqual(belowSearchBar(searched, try mount(variant: .second, query: "idle cap")).count, 0,
                       "a session whose task does not match still drew a row")

        XCTAssertGreaterThan(
            belowSearchBar(try mount(variant: .first), try mount(variant: .second)).count, 0,
            "without a query the other session's row must be visible, or the zero above proves nothing"
        )
        XCTAssertGreaterThan(belowSearchBar(searched, try mount(variant: .first, query: "nothing matches")).count, 0,
                             "the matching session must be drawn, or the zero above is two empty tables")
    }

    func testAPortQueryNarrowsThePortsSectionFromTheSameField() throws {
        let searched = try mount(variant: .first, ports: true, query: ":3000")
        XCTAssertEqual(
            belowSearchBar(searched, try mount(variant: .second, ports: true, query: ":3000")).count, 0,
            "a port that does not match, or a session, still drew a row"
        )
        XCTAssertGreaterThan(
            belowSearchBar(try mount(variant: .first, ports: true), try mount(variant: .second, ports: true)).count, 0,
            "without a query the other session and its port must be visible, or the zero above proves nothing"
        )
        XCTAssertGreaterThan(
            belowSearchBar(searched, try mount(variant: .first, ports: true, query: "nothing matches")).count, 0,
            "port 3000 must be drawn, or the zero above is two empty sections"
        )

        let byTask = try mount(variant: .first, ports: true, query: "idle cap")
        XCTAssertEqual(
            belowSearchBar(byTask, try mount(variant: .second, ports: true, query: "idle cap")).count, 0,
            "one query must drop the other session's row and its port together"
        )
        XCTAssertGreaterThan(belowSearchBar(byTask, searched).count, 0,
                             "the task query must bring back the idle session that the port query hid")
    }

    /// Consistent with an epic lane on the Task Board: a ports section with no match is not drawn,
    /// header and divider included, exactly as when the project holds no ports.
    func testAPortsSectionWithNoMatchDisappearsHeaderAndAll() throws {
        let searched = try mount(variant: .first, ports: true, query: "watchdog")
        let portless = try mount(variant: .first, query: "watchdog")
        let noMatch = try mount(variant: .first, ports: true, query: "nothing matches")
        XCTAssertGreaterThan(belowSearchBar(searched, portless).count, 0,
                             "port 3000's owner is the watchdog task, so the section must draw here")
        XCTAssertEqual(
            belowSearchBar(noMatch, try mount(variant: .first, query: "nothing matches")).count, 0,
            "a ports section with nothing matching left a header, a divider or a gap behind"
        )
    }

    func testClearingTheQueryRestoresEveryRow() throws {
        let mounted = try mount(variant: .first, ports: true)
        let unsearched = mounted.capture
        type("idle cap", into: mounted.mount)
        let searched = try mounted.mount.capture()
        type("", into: mounted.mount)
        let cleared = try mounted.mount.capture()

        XCTAssertGreaterThan(unsearched.diff(searched, columns: 0..<unsearched.width).count, 0,
                             "typing must have narrowed the pane, or the restore below proves nothing")
        XCTAssertEqual(unsearched.diff(cleared, columns: 0..<unsearched.width).count, 0,
                       "clearing the query left the pane different from before it was typed")
    }

    // MARK: fixtures

    private struct Mounted {
        let mount: OffscreenMount
        let capture: Capture
        let searchBarBottom: CGFloat
    }

    private enum Variant {
        case first, second

        var otherState: SessionState { self == .first ? .completed : .failed }
        var otherCommand: String { self == .first ? "vite" : "python3" }
    }

    private func mount(variant: Variant, ports: Bool = false, query: String = "") throws -> Mounted {
        let db = try AppDatabase.inMemory()
        let project = try ProjectStore(db).register(
            name: "search", repoPath: "/tmp/status-search-\(UUID().uuidString)", baseBranch: "main",
            worktreeRoot: "/tmp/status-search-worktrees", memoryDir: nil
        )
        let endedAt = Int64.nowMillis - 60_000
        for (id, title, state) in [("s-idle", Self.idle, SessionState.completed), ("s-other", "Port sweep", variant.otherState)] {
            let task = try TaskStore(db).create(
                projectId: project.id, title: title, body: nil, acceptance: nil, priority: nil,
                column: .done, origin: .human, epicId: nil
            )
            try SessionStore(db).insert(AgentSession(
                sessionId: id, shortId: id, projectId: project.id, taskId: task.id, role: .worker, cwd: "/tmp",
                state: state, startedAt: endedAt - 60_000, endedAt: endedAt
            ))
        }
        let listening = ports ? try model(db, [
            ListeningPort(port: 3000, pid: 501, command: "node", sessionId: "s-idle", source: .ledger),
            ListeningPort(port: 5173, pid: 502, command: variant.otherCommand, sessionId: "s-other", source: .ledger),
        ]) : nil
        let mount = OffscreenMount(
            StatusView(project: project).environment(renderEnvironment(db: db, listeningPorts: listening))
        )
        mounts.append(mount)
        mount.window.layoutIfNeeded()
        if !query.isEmpty { type(query, into: mount) }
        let field = try searchField(in: mount)
        let frame = field.convert(field.bounds, to: nil)
        return Mounted(
            mount: mount, capture: try mount.capture(),
            searchBarBottom: mount.window.frame.height - frame.minY + 12
        )
    }

    private func model(_ db: AppDatabase, _ rows: [ListeningPort]) throws -> ListeningPortModel {
        let model = ListeningPortModel(
            db: db,
            ledger: PIDSessionLedger(url: ledgerDir.appendingPathComponent("\(UUID().uuidString).json")),
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

    private func type(_ text: String, into mount: OffscreenMount) {
        guard let field = try? searchField(in: mount) else { return XCTFail("no search field mounted") }
        field.stringValue = text
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    private func searchField(in mount: OffscreenMount) throws -> NSTextField {
        var queue: [NSView] = [mount.host]
        var fields: [NSTextField] = []
        while let view = queue.popLast() {
            if let field = view as? NSTextField, field.isEditable { fields.append(field) }
            queue.append(contentsOf: view.subviews)
        }
        XCTAssertEqual(fields.count, 1, "the pane should hold exactly one editable field, its search")
        return try XCTUnwrap(fields.first)
    }

    private func belowSearchBar(_ left: Mounted, _ right: Mounted) -> PixelDiff {
        let top = max(left.searchBarBottom, right.searchBarBottom)
        return left.capture.diff(right.capture, columns: 0..<left.capture.width, rows: left.capture.rows(below: top))
    }
}
