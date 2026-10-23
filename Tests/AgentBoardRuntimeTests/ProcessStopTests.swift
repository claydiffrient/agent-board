import AgentBoardRuntime
import Darwin
import Foundation
import XCTest

/// What the process view's Stop may signal (SPEC §8.7), decided from fabricated tables.
final class ProcessStopPlannerTests: XCTestCase {
    private static let me: uid_t = 501
    private static let shell = ProcessOwner(role: .humanShell, projectId: "p-1")

    private static func entry(_ ppid: pid_t, _ command: String, pgid: pid_t, uid: uid_t = me) -> ProcessTable.Entry {
        ProcessTable.Entry(ppid: ppid, command: command, startedAtMicros: 1_000, pgid: pgid, uid: uid)
    }

    /// Agent Board (100) under 40, with its git helper, a shell console running `npm` and an
    /// interactive `claude`, a root-owned `sudo`, a worker host (300) and an orchestrator (400).
    private static let table = ProcessTable(entries: [
        40: entry(1, "launcher", pgid: 40),
        100: entry(40, "AgentBoard", pgid: 100),
        101: entry(100, "git", pgid: 100),
        120: entry(101, "ssh", pgid: 100, uid: 0),
        102: entry(100, "zsh", pgid: 102),
        103: entry(102, "npm", pgid: 103),
        104: entry(103, "node", pgid: 103),
        105: entry(102, "claude", pgid: 105),
        130: entry(100, "sudo", pgid: 130, uid: 0),
        300: entry(1, "2.1.300", pgid: 300),
        301: entry(300, "zsh", pgid: 301),
        302: entry(301, "swift-build", pgid: 301),
        400: entry(100, "claude", pgid: 400),
        900: entry(1, "Safari", pgid: 900),
    ])

    private static let inventory = ProcessInventory.build(
        table: table,
        roots: [
            InventoryRoot(pid: 300, owner: ProcessOwner(role: .worker, projectId: "p-1", taskId: "t-1", sessionId: "s-1")),
            InventoryRoot(pid: 400, owner: ProcessOwner(role: .orchestrator, projectId: "p-1", sessionId: "s-orch")),
            InventoryRoot(pid: 102, owner: shell),
            InventoryRoot(pid: 100, owner: .agentBoard),
        ],
        facts: { _ in nil }
    )

    private static func id(_ pid: pid_t, startedAt: Int64 = 1_000) -> PIDIdentity {
        PIDIdentity(pid: pid, startedAtMicros: startedAt)
    }

    func testEachRowIsRoutedOrRefusedBeforeAnythingIsSignalled() {
        let restarted = ProcessTable(entries: Self.table.entries.merging(
            [104: ProcessTable.Entry(ppid: 103, command: "node", startedAtMicros: 2_000, pgid: 103, uid: Self.me)]
        ) { _, new in new })
        let protected: Set<pid_t> = [300, 100, 40]

        let cases: [(String, PIDIdentity, ProcessTable, [pid_t: String], Result<ProcessStopPlan, ProcessStopRefusal>)] = [
            ("Agent Board itself", Self.id(100), Self.table, [300: "s-1"], .failure(.agentBoard(100))),
            ("an ancestor of Agent Board", Self.id(40), Self.table, [300: "s-1"], .failure(.agentBoard(40))),
            ("a worker's host", Self.id(300), Self.table, [300: "s-1"], .success(.session("s-1"))),
            ("a host the registry gives another session", Self.id(300), Self.table, [300: "s-2"], .failure(.sessionHost(300))),
            ("an orchestrator's host", Self.id(400), Self.table, [300: "s-1"], .failure(.consoleHost)),
            ("a shell whose tree holds a claude", Self.id(102), Self.table, [300: "s-1"], .failure(.sessionHost(105))),
            ("a pid outside the inventory", Self.id(900), Self.table, [300: "s-1"], .failure(.notInInventory)),
            ("an identity the row never drew", Self.id(104, startedAt: 2_000), restarted, [300: "s-1"], .failure(.notInInventory)),
            ("a pid reused since the row was drawn", Self.id(104), restarted, [300: "s-1"], .failure(.identityChanged)),
            ("another user's process", Self.id(130), Self.table, [300: "s-1"], .failure(.otherUser(130))),
            ("another user's process under the row", Self.id(101), Self.table, [300: "s-1"], .failure(.otherUser(120))),
            ("a dev server that leads its own group", Self.id(103), Self.table, [300: "s-1"], .success(.tree(ProcessTreeStop(
                root: Self.id(103), members: [Self.id(103), Self.id(104)], group: 103, protected: protected, uid: Self.me
            )))),
            ("a build in its parent's group", Self.id(302), Self.table, [300: "s-1"], .success(.tree(ProcessTreeStop(
                root: Self.id(302), members: [Self.id(302)], group: nil, protected: protected, uid: Self.me
            )))),
        ]

        for (name, row, table, hosts, expected) in cases {
            let result: Result<ProcessStopPlan, ProcessStopRefusal>
            do {
                result = .success(try ProcessStopPlanner.plan(
                    row, inventory: Self.inventory, table: table, hosts: hosts,
                    isClaude: { [105, 300, 400].contains($0) }, board: 100, uid: Self.me
                ))
            } catch let refusal as ProcessStopRefusal {
                result = .failure(refusal)
            } catch {
                XCTFail("\(name): \(error)")
                continue
            }
            XCTAssertEqual(result, expected, name)
        }
    }
}

/// The signalling half, against a real tree with one member that ignores SIGTERM.
final class ProcessTreeStopTests: XCTestCase {
    private var leader: Process?
    private var pids: [pid_t] = []
    private var directory: URL?

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"), "no /usr/bin/python3")
    }

    override func tearDown() {
        for pid in pids { kill(pid, SIGKILL) }
        leader?.terminate()
        directory.map { try? FileManager.default.removeItem(at: $0) }
    }

    func testATreeGetsSIGTERMAndWhatIgnoresItGetsSIGKILLAfterTheGrace() async throws {
        let (root, stubborn, plain) = try startTree()
        let table = ProcessTable.current()
        let inventory = ProcessInventory.build(
            table: table,
            roots: [InventoryRoot(pid: root, owner: ProcessOwner(role: .humanShell, projectId: "p-1"))],
            facts: { _ in nil }
        )
        let row = try XCTUnwrap(table.identity(of: root))

        let plan = try ProcessStopPlanner.plan(
            row, inventory: inventory, table: table, hosts: [:],
            isClaude: ProcessStopPlanner.isClaude, board: getpid(), uid: getuid()
        )
        guard case .tree(let tree) = plan else { return XCTFail("planned \(plan)") }
        XCTAssertEqual(Set(tree.members.map(\.pid)), [root, stubborn, plain])

        let report = await PortStopper(grace: .seconds(1)).stop(tree)

        XCTAssertTrue(report.escalated, "the SIGTERM-ignoring child needed SIGKILL")
        XCTAssertEqual(report.survivors, [])
        for pid in [root, stubborn, plain] {
            XCTAssertFalse(isRunning(pid), "pid \(pid) outlived the stop")
        }
    }

    /// leader → root → (stubborn, which ignores SIGTERM; plain `sleep`). The leader waits on the
    /// root, so the root is never this test's own unreaped child.
    private func startTree() throws -> (pid_t, pid_t, pid_t) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentboard-processstop/\(UUID().uuidString)")
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = directory.appendingPathComponent("root.py")
        try """
        import os, subprocess, sys, time
        stubborn = subprocess.Popen([sys.executable, "-c",
            "import signal, sys, time\\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\\nprint('ready', flush=True)\\ntime.sleep(600)"],
            stdout=subprocess.PIPE)
        stubborn.stdout.readline()
        plain = subprocess.Popen(["/bin/sleep", "600"])
        print("TREE %d %d %d" % (os.getpid(), stubborn.pid, plain.pid), flush=True)
        time.sleep(600)
        """.write(to: root, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import subprocess, sys; subprocess.Popen([sys.executable, sys.argv[1]]).wait()", root.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        leader = process

        var buffer = ""
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, !buffer.contains("\n") {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { Thread.sleep(forTimeInterval: 0.05) } else { buffer += String(decoding: chunk, as: UTF8.self) }
        }
        let fields = buffer.split(whereSeparator: \.isWhitespace).dropFirst().compactMap { pid_t($0) }
        guard fields.count == 3 else { throw AgentRuntimeError("the tree announced only: \(buffer)") }
        pids = fields
        return (fields[0], fields[1], fields[2])
    }

    private func isRunning(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return info.pbi_status != SZOMB
    }
}
