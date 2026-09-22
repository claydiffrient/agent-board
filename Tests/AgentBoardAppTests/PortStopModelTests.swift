import AgentBoardCore
import AgentBoardRuntime
import AgentBoardServer
import Darwin
import Foundation
import XCTest
@testable import AgentBoard

/// Records what the model handed the stopper and answers with whatever the test wants back.
private final class StopperSpy: @unchecked Sendable {
    struct Call: Equatable {
        let port: Int
        let pid: pid_t
        let boardServerPort: Int?
        let protected: Set<pid_t>
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let answer: @Sendable (Int, pid_t) throws -> PortStopReport

    init(answer: @escaping @Sendable (Int, pid_t) throws -> PortStopReport = { _, _ in
        PortStopReport(scope: .processGroup(1234), escalated: false, outcome: .stopped)
    }) {
        self.answer = answer
    }

    var calls: [Call] { lock.withLock { recorded } }

    func stop(_ port: Int, _ pid: pid_t, _ boardServerPort: Int?, _ protected: Set<pid_t>) async throws -> PortStopReport {
        lock.withLock {
            recorded.append(Call(port: port, pid: pid, boardServerPort: boardServerPort, protected: protected))
        }
        return try answer(port, pid)
    }
}

/// One fixed sweep result, so a stop's effect on the rows is the test's own doing rather than the
/// machine's.
private final class FixedSweep: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [ListeningPort]

    init(_ rows: [ListeningPort]) { self.rows = rows }

    func replace(with rows: [ListeningPort]) { lock.withLock { self.rows = rows } }

    func sweep(_ owners: [pid_t: String], _ remembered: [PIDIdentity: String], _ port: Int?) -> PortSweepResult {
        PortSweepResult(ports: lock.withLock { rows }, attributions: [:], liveIdentities: [])
    }
}

@MainActor
final class PortStopModelTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentboard-portstop-model/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func model(
        db: AppDatabase,
        sweep: FixedSweep,
        stopper: StopperSpy,
        boardServerPort: Int? = nil,
        shellPIDs: [String: pid_t] = [:],
        agentPIDs: [pid_t: String] = [:]
    ) -> ListeningPortModel {
        ListeningPortModel(
            db: db,
            ledger: PIDSessionLedger(url: directory.appendingPathComponent("owners.json")),
            boardServerPort: { boardServerPort },
            shellConsolePIDs: { shellPIDs },
            agentPIDs: { agentPIDs },
            sweep: sweep.sweep,
            stopper: stopper.stop
        )
    }

    func testAStoppedPortsRowIsGoneWithoutWaitingForTheHourlySweep() async throws {
        let db = try AppDatabase.inMemory()
        let sweep = FixedSweep([ListeningPort(port: 3000, pid: 900, command: "node", sessionId: nil)])
        let spy = StopperSpy()
        let model = model(db: db, sweep: sweep, stopper: spy)
        await model.refreshAndWait()
        let row = try XCTUnwrap(model.ports.first)

        sweep.replace(with: [])
        await model.stop(row)

        XCTAssertEqual(spy.calls.map(\.port), [3000])
        XCTAssertEqual(model.ports, [], "the row waited for the hourly sweep instead of the stop's own refresh")
        XCTAssertNil(model.stopFailure(for: row))
    }

    /// Dropping a row for a process that is still listening would be worse than showing the
    /// failure: the human would find the port again with `lsof` an hour later.
    func testARowWhoseProcessSurvivesTheEscalationStaysAndSaysSo() async throws {
        let db = try AppDatabase.inMemory()
        let sweep = FixedSweep([ListeningPort(port: 3000, pid: 900, command: "node", sessionId: nil)])
        let spy = StopperSpy { _, _ in
            PortStopReport(scope: .processGroup(900), escalated: true, outcome: .stillListening)
        }
        let model = model(db: db, sweep: sweep, stopper: spy)
        await model.refreshAndWait()
        let row = try XCTUnwrap(model.ports.first)

        await model.stop(row)

        XCTAssertEqual(model.ports.map(\.port), [3000], "a row that is still listening was dropped")
        XCTAssertEqual(model.stopFailure(for: row), "Still listening after SIGKILL")
    }

    /// The pid changes when a supervisor respawns, so a failure keyed on the row id would be
    /// pruned by the very refresh that proves the port was never released.
    func testAFailureSurvivesTheProcessComingBackUnderANewPid() async throws {
        let db = try AppDatabase.inMemory()
        let sweep = FixedSweep([ListeningPort(port: 3000, pid: 900, command: "node", sessionId: nil)])
        let spy = StopperSpy { _, _ in
            PortStopReport(scope: .processOnly(900), escalated: true, outcome: .stillListening)
        }
        let model = model(db: db, sweep: sweep, stopper: spy)
        await model.refreshAndWait()
        let row = try XCTUnwrap(model.ports.first)

        sweep.replace(with: [ListeningPort(port: 3000, pid: 901, command: "node", sessionId: nil)])
        await model.stop(row)

        let respawned = try XCTUnwrap(model.ports.first)
        XCTAssertEqual(respawned.pid, 901, "the fixture did not respawn under a new pid")
        XCTAssertEqual(
            model.stopFailure(for: respawned), "Still listening after SIGKILL",
            "a port that was never released came back looking like a clean stop"
        )
    }

    func testTheFailureClearsOnceTheRowIsGone() async throws {
        let db = try AppDatabase.inMemory()
        let sweep = FixedSweep([ListeningPort(port: 3000, pid: 900, command: "node", sessionId: nil)])
        let survives = StopperSpy { _, _ in
            PortStopReport(scope: .processGroup(900), escalated: true, outcome: .stillListening)
        }
        let model = model(db: db, sweep: sweep, stopper: survives)
        await model.refreshAndWait()
        let row = try XCTUnwrap(model.ports.first)
        await model.stop(row)
        XCTAssertNotNil(model.stopFailure(for: row))

        sweep.replace(with: [])
        await model.refreshAndWait()

        XCTAssertEqual(model.stopFailures, [:], "a failure outlived the row it belonged to")
    }

    /// The board's own pid, its process group, every `claude` session host and every shell console
    /// shell. A stop that signalled one of those groups would take agents down with a dev server.
    func testTheStopIsHandedTheBoardsOwnPortAndEveryProtectedPID() async throws {
        let db = try AppDatabase.inMemory()
        let sweep = FixedSweep([ListeningPort(port: 3000, pid: 900, command: "node", sessionId: nil)])
        let spy = StopperSpy()
        let model = model(
            db: db, sweep: sweep, stopper: spy, boardServerPort: 47_100,
            shellPIDs: ["p-1": 777], agentPIDs: [555: "s-1"]
        )
        await model.refreshAndWait()

        await model.stop(try XCTUnwrap(model.ports.first))

        let call = try XCTUnwrap(spy.calls.first)
        XCTAssertEqual(call.boardServerPort, 47_100)
        XCTAssertTrue(call.protected.contains(ProcessInfo.processInfo.processIdentifier))
        XCTAssertTrue(call.protected.contains(getpgrp()))
        XCTAssertTrue(call.protected.contains(555), "a claude session host was left unprotected")
        XCTAssertTrue(call.protected.contains(777), "a shell console's shell was left unprotected")
    }

    func testASecondStopOfTheSameRowWhileOneIsInFlightDoesNotSignalTwice() async throws {
        let db = try AppDatabase.inMemory()
        let sweep = FixedSweep([ListeningPort(port: 3000, pid: 900, command: "node", sessionId: nil)])
        let spy = StopperSpy()
        let model = model(db: db, sweep: sweep, stopper: spy)
        await model.refreshAndWait()
        let row = try XCTUnwrap(model.ports.first)

        async let first: Void = model.stop(row)
        async let second: Void = model.stop(row)
        _ = await (first, second)

        XCTAssertEqual(spy.calls.count, 1)
    }

    /// The refusal reaches the row rather than vanishing: a stop that was refused must not read as
    /// a stop that worked.
    func testARefusalIsShownOnTheRow() async throws {
        let db = try AppDatabase.inMemory()
        let sweep = FixedSweep([ListeningPort(port: 3000, pid: 900, command: "node", sessionId: nil)])
        let spy = StopperSpy { port, _ in throw PortStopRefusal.boardServerPort(port) }
        let model = model(db: db, sweep: sweep, stopper: spy)
        await model.refreshAndWait()
        let row = try XCTUnwrap(model.ports.first)

        await model.stop(row)

        XCTAssertEqual(model.stopFailure(for: row), "Agent Board's own port — refused")
        XCTAssertEqual(model.ports.map(\.port), [3000])
    }
}

/// The stop path against `BoardServer`'s real bound port.
///
/// The sweep already drops it, so no row for it can exist. This is the second wall: a stop path
/// that could ever be handed the board's port is a path that can kill every agent on the machine,
/// and the check costs one comparison.
final class BoardServerPortStopRefusalTests: XCTestCase {
    private var server: BoardServer!
    private var boundPort = 0

    override func setUp() async throws {
        server = BoardServer(tokens: NoStopTokens(), hooks: NoStopHooks(), tools: NoStopTools())
        boundPort = try await server.start()
    }

    override func tearDown() async throws {
        await server.stop()
        server = nil
    }

    func testTheBoardsBoundPortIsRefusedWhenHandedToTheStopperDirectly() async throws {
        let reported = await server.port
        let port = try XCTUnwrap(reported)
        XCTAssertEqual(port, boundPort)
        let us = ProcessInfo.processInfo.processIdentifier
        XCTAssertTrue(
            ListeningPortSweep.holders(of: port).contains(us),
            "this process is not the one holding the board's port, so the refusal below proves nothing"
        )

        do {
            _ = try await PortStopper(grace: .milliseconds(200)).stop(
                port: port, pid: us, boardServerPort: port, protected: []
            )
            XCTFail("the board's own port was accepted for a stop")
        } catch let refusal as PortStopRefusal {
            XCTAssertEqual(refusal, .boardServerPort(port))
        }

        let stillBound = await server.port
        XCTAssertEqual(stillBound, port, "the refused stop disturbed the running server")
        XCTAssertTrue(ListeningPortSweep.holders(of: port).contains(us))
    }
}

private struct NoStopTokens: TokenResolver {
    func resolve(token: String) async -> TokenIdentity? { nil }
}

private struct NoStopHooks: HookSink {
    func handle(_ event: HookEvent, identity: TokenIdentity) async -> HookDecision? { nil }
}

private struct NoStopTools: ToolHandler {
    func tools(for identity: TokenIdentity) async -> [ToolDescriptor] { [] }
    func call(_ name: String, arguments: JSONValue, identity: TokenIdentity) async throws -> ToolResult {
        ToolResult(text: "")
    }
}
