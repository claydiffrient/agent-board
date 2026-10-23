import AgentBoardRuntime
import Darwin
import Foundation
import XCTest

final class ProcessInventoryTests: XCTestCase {
    private let session = ProcessOwner(role: .worker, projectId: "p-1", taskId: "t-1", sessionId: "s-1")
    private let shell = ProcessOwner(role: .humanShell, projectId: "p-1")
    private let orchestrator = ProcessOwner(role: .orchestrator, projectId: "p-1", sessionId: "s-orch")
    private let worktree = "/agentboard-inventory-fixture/wt/s-1"

    private struct Row: Equatable {
        let owner: ProcessOwner
        let parent: pid_t?
        let orphan: Bool
        let ports: [Int]
    }

    func testEachProcessGoesToTheNearestRootOrWorktreeOrphanAndNothingElseIsListed() {
        let started: Int64 = 1_000
        func entry(_ ppid: pid_t, _ command: String, at start: Int64 = 2_000) -> ProcessTable.Entry {
            ProcessTable.Entry(ppid: ppid, command: command, startedAtMicros: start)
        }
        let table = ProcessTable(entries: [
            50: entry(1, "launchd-child"),
            100: entry(50, "AgentBoard"),
            101: entry(100, "git"),
            102: entry(100, "zsh"),
            103: entry(102, "npm"),
            104: entry(100, "claude"),
            200: entry(1, "claude"),
            300: entry(200, "2.1.300"),
            301: entry(300, "zsh"),
            302: entry(301, "swift-build"),
            400: entry(1, "zsh"),
            401: entry(400, "swift-test"),
            500: entry(1, "Safari"),
            501: entry(1, "zsh"),
            502: entry(1, "node", at: started - 1),
            503: entry(50, "Chrome"),
        ])
        let facts: [pid_t: ProcessFacts] = [
            200: ProcessFacts(cwd: worktree, hasControllingTerminal: false, isClaude: true),
            400: ProcessFacts(cwd: worktree + "/Sources", hasControllingTerminal: false, isClaude: false),
            500: ProcessFacts(cwd: "/Users/someone", hasControllingTerminal: false, isClaude: false),
            501: ProcessFacts(cwd: worktree, hasControllingTerminal: true, isClaude: false),
            502: ProcessFacts(cwd: worktree, hasControllingTerminal: false, isClaude: false),
        ]
        let roots = [
            InventoryRoot(pid: 300, owner: session, worktree: WorktreeClaim(path: worktree, startedAtMicros: started)),
            InventoryRoot(pid: 102, owner: shell),
            InventoryRoot(pid: 104, owner: orchestrator),
            InventoryRoot(pid: 100, owner: .agentBoard),
        ]
        let ports = [ListeningPort(port: 3000, pid: 302, command: "swift-build", sessionId: "s-1")]

        let inventory = ProcessInventory.build(table: table, roots: roots, ports: ports) { facts[$0] }
        let rows = Dictionary(uniqueKeysWithValues: inventory.processes.map {
            ($0.pid, Row(owner: $0.owner, parent: $0.parent, orphan: $0.isWorktreeOrphan, ports: $0.ports))
        })

        XCTAssertEqual(rows, [
            300: Row(owner: session, parent: nil, orphan: false, ports: []),
            301: Row(owner: session, parent: 300, orphan: false, ports: []),
            302: Row(owner: session, parent: 301, orphan: false, ports: [3000]),
            400: Row(owner: session, parent: nil, orphan: true, ports: []),
            401: Row(owner: session, parent: 400, orphan: false, ports: []),
            102: Row(owner: shell, parent: nil, orphan: false, ports: []),
            103: Row(owner: shell, parent: 102, orphan: false, ports: []),
            104: Row(owner: orchestrator, parent: nil, orphan: false, ports: []),
            100: Row(owner: .agentBoard, parent: nil, orphan: false, ports: []),
            101: Row(owner: .agentBoard, parent: 100, orphan: false, ports: []),
        ])
    }

    func testCPUNeedsTwoReadingsOfTheSameIdentity() throws {
        var sampler = ProcessUsageSampler()
        let original = PIDIdentity(pid: 700, startedAtMicros: 1)
        let reused = PIDIdentity(pid: 700, startedAtMicros: 2)

        let first = sampler.sample([original: TaskReading(cpuNanos: 1_000, residentBytes: 4096)], atNanos: 0)
        XCTAssertEqual(first[original], ProcessUsage(cpuPercent: nil, residentBytes: 4096))

        let second = sampler.sample([original: TaskReading(cpuNanos: 501_000, residentBytes: 8192)], atNanos: 1_000_000)
        XCTAssertEqual(try XCTUnwrap(second[original]?.cpuPercent), 50, accuracy: 0.001)

        let afterReuse = sampler.sample([reused: TaskReading(cpuNanos: 2_000_000, residentBytes: 4096)], atNanos: 2_000_000)
        XCTAssertEqual(afterReuse[reused], ProcessUsage(cpuPercent: nil, residentBytes: 4096))
    }

    func testARealSleepChildIsListedUnderAgentBoardWithItsMemory() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        addTeardownBlock { child.terminate(); child.waitUntilExit() }

        var sampler = ProcessUsageSampler()
        var found: InventoryProcess?
        var sampled: SampledInventory?
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let snapshot = LiveProcessSampler.sample(roots: [], ports: [], sampler: &sampler)
            found = snapshot.inventory.processes.first { $0.pid == child.processIdentifier && $0.command == "sleep" }
            sampled = snapshot
            if found != nil { break }
            Thread.sleep(forTimeInterval: 0.05)
        }

        let process = try XCTUnwrap(found, "the sleep child never appeared in the inventory")
        XCTAssertEqual(process.owner, .agentBoard)
        XCTAssertGreaterThan(try XCTUnwrap(sampled?.usage[process.identity]).residentBytes, 0)
    }
}
