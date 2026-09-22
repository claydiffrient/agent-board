import AgentBoardRuntime
import Darwin
import Foundation
import XCTest

/// A real listening process under a real group leader, shaped like `npm run dev`.
///
/// The leader calls `setpgrp()` and then forks the listener, so the listener sits in its parent's
/// process group without leading one — which is what a measured `npm run dev` looks like under an
/// interactive shell (listening `node` pgid == `npm`'s pid, the shell in a third group of its own).
/// A fixture where the listener led its own group would make the group check pass vacuously.
final class ListenerGroupFixture {
    let leaderPID: pid_t
    let listenerPID: pid_t
    let port: Int

    private let process: Process
    private let directory: URL

    static let pythonPath = "/usr/bin/python3"

    static var isSupported: Bool {
        FileManager.default.isExecutableFile(atPath: pythonPath)
    }

    /// - Parameter ignoreHangUp: the listener installs `SIG_IGN` for SIGHUP, so only the escalation
    ///   can end it.
    init(ignoreHangUp: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentboard-portstop/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let listener = directory.appendingPathComponent("listener.py")
        let leader = directory.appendingPathComponent("leader.py")

        try """
        import os, signal, socket, sys, time
        \(ignoreHangUp ? "signal.signal(signal.SIGHUP, signal.SIG_IGN)" : "")
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        s.listen(5)
        print("LISTENER %d %d" % (os.getpid(), s.getsockname()[1]), flush=True)
        time.sleep(600)
        """.write(to: listener, atomically: true, encoding: .utf8)

        // setpgrp() first, so the leader's pid is the group every later child inherits.
        try """
        import os, subprocess, sys, time
        os.setpgrp()
        print("LEADER %d" % os.getpid(), flush=True)
        subprocess.Popen([sys.executable, "\(listener.path)"]).wait()
        """.write(to: leader, atomically: true, encoding: .utf8)

        process = Process()
        process.executableURL = URL(fileURLWithPath: Self.pythonPath)
        process.arguments = [leader.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()

        let announced = try Self.readLines(2, from: output.fileHandleForReading, timeout: 30)
        func field(_ line: String, _ index: Int) throws -> Int {
            let fields = line.split(separator: " ")
            guard fields.count > index, let value = Int(fields[index]) else {
                throw AgentRuntimeError("unparsable announcement: \(line)")
            }
            return value
        }
        leaderPID = pid_t(try field(announced[0], 1))
        listenerPID = pid_t(try field(announced[1], 1))
        port = try field(announced[1], 2)
    }

    func tearDown() {
        for pid in [listenerPID, leaderPID] where pid > 1 { kill(pid, SIGKILL) }
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
        throw AgentRuntimeError("fixture announced only: \(buffer)")
    }
}

/// What the stop is allowed to signal. Fabricated tables, because the question is a decision about
/// the shape of a tree rather than anything the kernel has to answer.
final class PortStopPlannerTests: XCTestCase {
    /// The measured `npm run dev` shape: listener 300 under leader 200, shell 100 in its own group.
    private let npmShaped = ProcessTable(entries: [
        100: .init(ppid: 1, command: "zsh", pgid: 100),
        200: .init(ppid: 100, command: "npm", pgid: 200),
        300: .init(ppid: 200, command: "node", pgid: 200),
    ])

    func testAListenerThatIsNotTheGroupLeaderSignalsItsParentsGroupRatherThanItsOwnPid() {
        let scope = PortStopPlanner.scope(listener: 300, table: npmShaped, protected: [])

        XCTAssertEqual(
            scope, .processGroup(200),
            "kill(-300, …) addresses the group whose id is 300, and there is no such group"
        )
    }

    /// The shell is a different group. Killing the job must not reach it.
    func testTheGroupItSignalsDoesNotContainTheShellAboveIt() {
        XCTAssertEqual(npmShaped.members(ofGroup: 200), [200, 300])
        XCTAssertFalse(npmShaped.members(ofGroup: 200).contains(100))
    }

    func testAListenerThatLeadsItsOwnGroupSignalsThatGroup() {
        let table = ProcessTable(entries: [
            100: .init(ppid: 1, command: "zsh", pgid: 100),
            300: .init(ppid: 100, command: "node", pgid: 300),
        ])

        XCTAssertEqual(PortStopPlanner.scope(listener: 300, table: table, protected: []), .processGroup(300))
    }

    /// The reason the check exists: a group led by a `claude` session host would take the session
    /// down with the dev server.
    func testAProtectedGroupLeaderIsNeverSignalledAsAGroup() {
        let scope = PortStopPlanner.scope(listener: 300, table: npmShaped, protected: [200])

        XCTAssertEqual(scope, .processOnly(300))
    }

    /// A group can reach sideways: if any member is protected, the leader being an ancestor is not
    /// enough.
    func testAGroupHoldingAProtectedSiblingIsNotSignalled() {
        let table = ProcessTable(entries: [
            100: .init(ppid: 1, command: "zsh", pgid: 100),
            200: .init(ppid: 100, command: "npm", pgid: 200),
            300: .init(ppid: 200, command: "node", pgid: 200),
            400: .init(ppid: 200, command: "claude", pgid: 200),
        ])

        XCTAssertEqual(PortStopPlanner.scope(listener: 300, table: table, protected: [400]), .processOnly(300))
    }

    /// A leader that is not on the listener's ancestor chain would mean signalling a tree the human
    /// never looked at.
    func testALeaderOffTheAncestorChainFallsBackToThePidAlone() {
        let table = ProcessTable(entries: [
            100: .init(ppid: 1, command: "zsh", pgid: 100),
            200: .init(ppid: 100, command: "npm", pgid: 999),
            300: .init(ppid: 200, command: "node", pgid: 999),
            999: .init(ppid: 1, command: "unrelated", pgid: 999),
        ])

        XCTAssertEqual(PortStopPlanner.scope(listener: 300, table: table, protected: []), .processOnly(300))
    }

    func testAPidTheTableDoesNotKnowIsSignalledAlone() {
        XCTAssertEqual(PortStopPlanner.scope(listener: 4242, table: npmShaped, protected: []), .processOnly(4242))
    }

    func testTheSignalTargetIsNegatedForAGroupAndNotForAPid() {
        XCTAssertEqual(PortStopScope.processGroup(200).signalTarget, -200)
        XCTAssertEqual(PortStopScope.processOnly(300).signalTarget, 300)
    }
}

/// The signalling half, against processes that really hold sockets.
final class PortStopperTests: XCTestCase {
    private var fixture: ListenerGroupFixture?

    override func setUpWithError() throws {
        try XCTSkipUnless(ListenerGroupFixture.isSupported, "no /usr/bin/python3 to hold a socket")
    }

    override func tearDown() {
        fixture?.tearDown()
        fixture = nil
    }

    func testARealListeningProcessIsStoppedAndItsSocketIsGone() async throws {
        let fixture = try ListenerGroupFixture()
        self.fixture = fixture
        XCTAssertEqual(ListeningPortSweep.holders(of: fixture.port), [fixture.listenerPID])

        let report = try await PortStopper(grace: .seconds(4)).stop(
            port: fixture.port, pid: fixture.listenerPID, boardServerPort: nil, protected: []
        )

        XCTAssertEqual(report.outcome, .stopped)
        XCTAssertEqual(ListeningPortSweep.holders(of: fixture.port), [], "the socket outlived the stop")
    }

    /// The listener is not the group leader in this tree, so a stop that signalled `-listenerPID`
    /// would signal nothing. The group it does signal is its parent's.
    func testTheGroupItSignalsIsTheParentsAndItTakesTheParentDownToo() async throws {
        let fixture = try ListenerGroupFixture()
        self.fixture = fixture
        let table = ProcessTable.current()
        XCTAssertEqual(table.entries[fixture.listenerPID]?.pgid, fixture.leaderPID)
        XCTAssertNotEqual(fixture.listenerPID, fixture.leaderPID, "the fixture must not lead its own group")

        let report = try await PortStopper(grace: .seconds(4)).stop(
            port: fixture.port, pid: fixture.listenerPID, boardServerPort: nil, protected: []
        )

        XCTAssertEqual(report.scope, .processGroup(fixture.leaderPID))
        XCTAssertEqual(report.outcome, .stopped)
        try await waitUntilGone(fixture.leaderPID)
    }

    /// The escalation, on a process that installs `SIG_IGN` for SIGHUP. Without SIGKILL this socket
    /// is still there when the grace runs out.
    func testAProcessThatIgnoresSIGHUPIsKilledByTheEscalation() async throws {
        let fixture = try ListenerGroupFixture(ignoreHangUp: true)
        self.fixture = fixture

        let report = try await PortStopper(grace: .milliseconds(600)).stop(
            port: fixture.port, pid: fixture.listenerPID, boardServerPort: nil, protected: []
        )

        XCTAssertTrue(report.escalated, "SIGHUP was reported as sufficient against a process ignoring it")
        XCTAssertEqual(report.outcome, .stopped)
        XCTAssertEqual(ListeningPortSweep.holders(of: fixture.port), [])
    }

    func testStoppingAPortNothingIsListeningOnIsRefusedRatherThanSignallingAnything() async throws {
        let fixture = try ListenerGroupFixture()
        self.fixture = fixture
        let free = fixture.port

        _ = try await PortStopper(grace: .seconds(4)).stop(
            port: free, pid: fixture.listenerPID, boardServerPort: nil, protected: []
        )

        do {
            _ = try await PortStopper(grace: .milliseconds(200)).stop(
                port: free, pid: fixture.listenerPID, boardServerPort: nil, protected: []
            )
            XCTFail("a stop on a closed socket was accepted")
        } catch let refusal as PortStopRefusal {
            XCTAssertEqual(refusal, .notListening(port: free, pid: fixture.listenerPID))
        }
    }

    /// The refusal is checked before the process table is even read, so it holds for any port the
    /// caller names as the board's own — including one that is genuinely listening.
    func testTheNamedBoardServerPortIsRefusedEvenWhenItIsReallyListening() async throws {
        let fixture = try ListenerGroupFixture()
        self.fixture = fixture

        do {
            _ = try await PortStopper(grace: .milliseconds(200)).stop(
                port: fixture.port, pid: fixture.listenerPID,
                boardServerPort: fixture.port, protected: []
            )
            XCTFail("the board's own port was accepted for a stop")
        } catch let refusal as PortStopRefusal {
            XCTAssertEqual(refusal, .boardServerPort(fixture.port))
        }
        XCTAssertEqual(
            ListeningPortSweep.holders(of: fixture.port), [fixture.listenerPID],
            "the refused stop signalled something anyway"
        )
    }

    private func waitUntilGone(_ pid: pid_t, timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if ProcessTable.current().entries[pid] == nil { return }
            try await _Concurrency.Task.sleep(for: .milliseconds(50))
        }
        XCTFail("\(pid) was still alive after the group stop")
    }
}
