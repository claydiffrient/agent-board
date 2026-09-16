import AgentBoardRuntime
import Foundation
import XCTest

/// A real three-level tree — `sh` -> `sh` -> a python process holding a listening socket — standing
/// in for `npm run dev` -> node. Every level forks rather than execs, so the chain is genuinely
/// three deep; a fixture of pid numbers would prove nothing about `proc_pidinfo`.
final class ProcessTreeFixture {
    let topPID: pid_t
    let middlePID: pid_t
    let leafPID: pid_t
    let port: Int

    private let process: Process
    private let directory: URL

    private static let pythonPath = "/usr/bin/python3"

    static var isSupported: Bool {
        FileManager.default.isExecutableFile(atPath: pythonPath)
    }

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentboard-porttree/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let listener = directory.appendingPathComponent("listener.py")
        let middle = directory.appendingPathComponent("middle.sh")
        let top = directory.appendingPathComponent("top.sh")

        try """
        import os, socket, time
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        s.listen(5)
        print("L3 %d %d" % (os.getpid(), s.getsockname()[1]), flush=True)
        time.sleep(600)
        """.write(to: listener, atomically: true, encoding: .utf8)

        // `&` plus `wait` rather than a trailing command, so the shell cannot exec-optimise the
        // child away and collapse a level.
        try """
        echo "L2 $$"
        \(Self.pythonPath) \(listener.path) &
        wait
        """.write(to: middle, atomically: true, encoding: .utf8)

        try """
        echo "L1 $$"
        /bin/sh \(middle.path) &
        wait
        """.write(to: top, atomically: true, encoding: .utf8)

        process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [top.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()

        let announced = try Self.readLines(3, from: output.fileHandleForReading, timeout: 30)
        func pid(_ line: String) throws -> pid_t {
            let fields = line.split(separator: " ")
            guard fields.count >= 2, let value = pid_t(fields[1]) else {
                throw AgentRuntimeError("unparsable tree announcement: \(line)")
            }
            return value
        }
        topPID = try pid(announced[0])
        middlePID = try pid(announced[1])
        leafPID = try pid(announced[2])
        guard let portField = announced[2].split(separator: " ").last, let port = Int(portField) else {
            throw AgentRuntimeError("unparsable listener announcement: \(announced[2])")
        }
        self.port = port
    }

    /// Kills the middle process, leaving the listener reparented to pid 1.
    func orphanTheLeaf() throws {
        kill(middlePID, SIGKILL)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if ProcessTable.current().entries[leafPID]?.ppid == 1 { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw AgentRuntimeError("listener \(leafPID) never reparented")
    }

    func tearDown() {
        for pid in [leafPID, middlePID, topPID] where pid > 1 { kill(pid, SIGKILL) }
        process.terminate()
        try? FileManager.default.removeItem(at: directory)
    }

    private static func readLines(_ count: Int, from handle: FileHandle, timeout: TimeInterval) throws -> [String] {
        var buffer = ""
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let lines = buffer.split(separator: "\n", omittingEmptySubsequences: true)
            if lines.count >= count { return lines.prefix(count).map(String.init) }
            let chunk = handle.availableData
            if chunk.isEmpty { Thread.sleep(forTimeInterval: 0.05); continue }
            buffer += String(decoding: chunk, as: UTF8.self)
        }
        throw AgentRuntimeError("process tree announced only: \(buffer)")
    }
}

final class ListeningPortSweepTests: XCTestCase {
    private var tree: ProcessTreeFixture?

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessTreeFixture.isSupported, "no /usr/bin/python3 to hold a socket")
        tree = try ProcessTreeFixture()
    }

    override func tearDown() {
        tree?.tearDown()
        tree = nil
    }

    func testAPortOpenedThreeLevelsDownAttributesToTheTopOfTheTree() throws {
        let tree = try XCTUnwrap(self.tree)
        let ports = ListeningPortSweep.sweep(sessionPIDs: [tree.topPID: "session-top"], boardServerPort: nil)

        let row = try XCTUnwrap(ports.first { $0.pid == tree.leafPID }, "listener absent from the sweep")
        XCTAssertEqual(row.port, tree.port)
        XCTAssertEqual(row.sessionId, "session-top")
        XCTAssertTrue(row.command.lowercased().contains("python"), "unexpected command \(row.command)")
        XCTAssertEqual(ports.filter { $0.pid == tree.leafPID }.count, 1, "one socket, one row")
    }

    func testAChainThatReachesNoKnownSessionIsReportedUnattributedRatherThanDropped() throws {
        let tree = try XCTUnwrap(self.tree)
        let ports = ListeningPortSweep.sweep(sessionPIDs: [:], boardServerPort: nil)

        let row = try XCTUnwrap(ports.first { $0.port == tree.port }, "unattributed listener was dropped")
        XCTAssertNil(row.sessionId)
        XCTAssertEqual(row.pid, tree.leafPID)
        XCTAssertFalse(row.command.isEmpty)
    }

    /// The orphan case the next task depends on: once the middle process dies the listener's chain
    /// runs to pid 1, so the session it came from is unrecoverable from the process table. The
    /// socket is still reported, with its pid and command, and nothing else.
    func testAnOrphanedListenerIsStillReportedButLosesItsAttribution() throws {
        let tree = try XCTUnwrap(self.tree)
        try tree.orphanTheLeaf()

        let ports = ListeningPortSweep.sweep(sessionPIDs: [tree.topPID: "session-top"], boardServerPort: nil)

        let row = try XCTUnwrap(ports.first { $0.pid == tree.leafPID }, "orphaned listener was dropped")
        XCTAssertEqual(row.port, tree.port)
        XCTAssertNil(row.sessionId)
        XCTAssertTrue(row.command.lowercased().contains("python"))
        XCTAssertEqual(ProcessTable.current().entries[tree.leafPID]?.ppid, 1)
    }

    func testThePortIsExcludedWhenItIsNamedAsTheBoardServersOwn() throws {
        let tree = try XCTUnwrap(self.tree)
        let swept = ListeningPortSweep.sweep(sessionPIDs: [:], boardServerPort: tree.port)

        XCTAssertFalse(swept.contains { $0.port == tree.port })
    }

    func testTheChainWalkStopsOnACycleRatherThanSpinning() {
        let table = ProcessTable(entries: [
            7: .init(ppid: 9, command: "a"),
            9: .init(ppid: 7, command: "b"),
        ])

        XCTAssertNil(table.owner(of: 7, in: [pid_t(4242): "nobody"]))
    }
}
