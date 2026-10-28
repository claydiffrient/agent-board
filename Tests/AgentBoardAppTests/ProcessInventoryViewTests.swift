import AgentBoardCore
import AgentBoardRuntime
import AppKit
import SwiftUI
import XCTest
@testable import AgentBoard

/// At a Glance's Processes view (SPEC §10). The table mounts as an `NSTableView`, so its rows,
/// column titles and geometry are read from AppKit; cell text is not readable offscreen, so the
/// names and indentation are pinned on `ProcessRows`, which builds every row the table draws.
@MainActor
final class ProcessInventoryViewTests: XCTestCase {
    private struct Line: Equatable {
        let depth: Int
        let name: String
        let owner: String
    }

    func testTheHierarchyGroupsProjectThenOwnerAndIndentsEachTreeAndSortingFlattensIt() {
        let sample = Self.sample(alpha: "p-alpha", beta: "p-beta")
        let names = ["p-alpha": "Alpha", "p-beta": "Beta"]

        let rows = ProcessRows.hierarchy(sample, projectNames: names, taskTitles: ["t-1": "Fix the parser"])

        XCTAssertEqual(rows.map { Line(depth: $0.depth, name: $0.name, owner: $0.owner) }, [
            Line(depth: 0, name: "Alpha", owner: ""),
            Line(depth: 1, name: "Orchestrator", owner: "orchestrator"),
            Line(depth: 2, name: "claude", owner: "Alpha · orchestrator"),
            Line(depth: 1, name: "Fix the parser", owner: "worker"),
            Line(depth: 2, name: "2.1.300", owner: "Alpha · worker"),
            Line(depth: 3, name: "zsh", owner: "Alpha · worker"),
            Line(depth: 4, name: "swift-build", owner: "Alpha · worker"),
            Line(depth: 3, name: "zsh", owner: "Alpha · worker"),
            Line(depth: 0, name: "Beta", owner: ""),
            Line(depth: 1, name: "Shell", owner: "shell"),
            Line(depth: 2, name: "zsh", owner: "Beta · shell"),
            Line(depth: 3, name: "npm", owner: "Beta · shell"),
            Line(depth: 0, name: "Agent Board", owner: ""),
            Line(depth: 1, name: "AgentBoard", owner: "Agent Board"),
            Line(depth: 2, name: "git", owner: "Agent Board"),
        ])
        let build = rows[6]
        XCTAssertEqual(build.ports, [3000])
        XCTAssertEqual(ProcessCell.cpu(rows[5].cpuPercent), "—", "a first reading is unknown, not 0")
        XCTAssertEqual(rows[3].cpuPercent, 50, "an owner row sums its processes' known CPU")

        let flat = ProcessRows.flat(
            sample, projectNames: names, sortedBy: [KeyPathComparator(\ProcessRow.cpuSortKey, order: .reverse)]
        )
        XCTAssertEqual(flat.count, sample.inventory.processes.count)
        XCTAssertEqual(flat.first?.name, "swift-build")
        XCTAssertTrue(flat.allSatisfy { $0.kind == .process && $0.depth == 0 })

        XCTAssertEqual(
            ProcessCell.totals(ProcessRows.totals(sample)),
            "9 processes · 50.0% CPU · \(ProcessCell.memory(102 * 1_048_576))"
        )
    }

    func testAtTheMinimumDetailWidthTheTableShowsEveryRowAndColumnWithoutScrollingSideways() throws {
        let db = try AppDatabase.inMemory()
        let alpha = try register(db, "Alpha")
        let beta = try register(db, "Beta")
        let sampler = FakeSampler(Self.sample(alpha: alpha.id, beta: beta.id))
        let mount = OffscreenMount(
            AtAGlanceView(projects: [alpha, beta], workspaces: [], attention: [], select: { _ in }, mode: .processes)
                .environment(renderEnvironment(db: db, processSampler: sampler)),
            size: CGSize(width: MainWindowLayout.minimumDetailWidth, height: 548)
        )
        defer { mount.close() }

        pump(mount.window) { tables(in: mount.host).first?.numberOfRows == 15 }

        let table = try XCTUnwrap(tables(in: mount.host).first, "the process table never mounted")
        XCTAssertEqual(table.numberOfRows, 15, "three groups, Alpha's two owners, Beta's one and nine processes")
        let titles = table.tableColumns.map(\.headerCell.stringValue)
        XCTAssertEqual(titles, ["Process", "PID", "Owner", "CPU %", "Memory", "Uptime", "Ports"])
        let visible = try XCTUnwrap(table.enclosingScrollView).contentView.bounds
        XCTAssertLessThanOrEqual(table.bounds.width, visible.width + 0.5, "the table scrolls sideways")
        let frames = table.tableColumns.indices.map(table.rect(ofColumn:))
        XCTAssertLessThanOrEqual(try XCTUnwrap(frames.last).maxX, visible.maxX + 0.5, "Ports ends out of view: \(frames)")
        for (left, right) in zip(frames, frames.dropFirst()) {
            XCTAssertLessThanOrEqual(left.maxX, right.minX + 0.5, "columns overlap: \(frames)")
        }
    }

    func testSamplingRunsOnlyWhileTheProcessViewIsMounted() throws {
        let db = try AppDatabase.inMemory()
        let project = try register(db, "Alpha")
        let sampler = FakeSampler(Self.sample(alpha: project.id, beta: "p-beta"))
        let env = renderEnvironment(db: db, processSampler: sampler)

        let landing = OffscreenMount(
            AtAGlanceView(projects: [project], workspaces: [], attention: [], select: { _ in }).environment(env)
        )
        pumpBriefly(landing.window, turns: 20)
        XCTAssertEqual(sampler.started, 0, "At a Glance's landing page started the sampler")
        landing.close()

        let mount = OffscreenMount(ProcessInventoryView(projects: [project]).environment(env))
        defer { mount.close() }
        pump(mount.window) { sampler.started == 1 }
        XCTAssertEqual(sampler.stopped, 0)

        mount.window.contentView = NSView()
        pump(mount.window) { sampler.stopped == 1 }
        XCTAssertEqual(sampler.started, 1)
    }

    /// Alpha's worker and orchestrator, Beta's shell and Agent Board's own tree, with Safari
    /// running beside them and listed nowhere.
    private static func sample(alpha: String, beta: String) -> SampledInventory {
        func entry(_ ppid: pid_t, _ command: String, at start: Int64) -> ProcessTable.Entry {
            ProcessTable.Entry(ppid: ppid, command: command, startedAtMicros: start)
        }
        let table = ProcessTable(entries: [
            100: entry(1, "AgentBoard", at: 1_000),
            101: entry(100, "git", at: 1_100),
            102: entry(100, "zsh", at: 1_200),
            103: entry(102, "npm", at: 1_300),
            104: entry(100, "claude", at: 1_400),
            300: entry(1, "2.1.300", at: 1_500),
            301: entry(300, "zsh", at: 1_600),
            302: entry(301, "swift-build", at: 1_700),
            303: entry(300, "zsh", at: 1_800),
            500: entry(1, "Safari", at: 900),
        ])
        let roots = [
            InventoryRoot(pid: 300, owner: ProcessOwner(role: .worker, projectId: alpha, taskId: "t-1", sessionId: "s-1")),
            InventoryRoot(pid: 104, owner: ProcessOwner(role: .orchestrator, projectId: alpha, sessionId: "s-orch")),
            InventoryRoot(pid: 102, owner: ProcessOwner(role: .humanShell, projectId: beta)),
            InventoryRoot(pid: 100, owner: .agentBoard),
        ]
        let inventory = ProcessInventory.build(
            table: table, roots: roots,
            ports: [ListeningPort(port: 3000, pid: 302, command: "swift-build", sessionId: "s-1")],
            facts: { _ in nil }
        )
        let mb: UInt64 = 1_048_576
        var usage: [PIDIdentity: ProcessUsage] = [:]
        for process in inventory.processes where process.pid != 101 {
            usage[process.identity] = ProcessUsage(cpuPercent: process.pid == 302 ? 50 : nil, residentBytes: 10 * mb)
        }
        usage[PIDIdentity(pid: 302, startedAtMicros: 1_700)] = ProcessUsage(cpuPercent: 50, residentBytes: 32 * mb)
        return SampledInventory(inventory: inventory, usage: usage, sampledAt: Date(timeIntervalSince1970: 100))
    }

    private func register(_ db: AppDatabase, _ name: String) throws -> Project {
        try ProjectStore(db).register(
            name: name, repoPath: "/tmp/process-view-\(UUID().uuidString)", baseBranch: "main",
            worktreeRoot: "/tmp/process-view-worktrees", memoryDir: nil
        )
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

/// Counts streams started and ended; yields one sample and then waits, as a live sampler would.
private final class FakeSampler: ProcessSampling, @unchecked Sendable {
    private let sample: SampledInventory
    private let lock = NSLock()
    private var counts = (started: 0, stopped: 0)

    init(_ sample: SampledInventory) {
        self.sample = sample
    }

    var started: Int { lock.withLock { counts.started } }
    var stopped: Int { lock.withLock { counts.stopped } }

    func samples(every interval: Duration) -> AsyncStream<SampledInventory> {
        lock.withLock { counts.started += 1 }
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.onTermination = { [weak self] _ in self?.lock.withLock { self?.counts.stopped += 1 } }
            continuation.yield(sample)
        }
    }
}
