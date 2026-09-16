import AgentBoardCore
import AgentBoardRuntime
import Darwin
import Foundation
import GRDB
import XCTest
@testable import AgentBoard

/// Counts sweeps and can hold one open, so "did a second refresh start a second sweep" is answered
/// by a number rather than by timing.
private final class SweepSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var responses: [[ListeningPort]]
    private let gate: DispatchSemaphore?

    init(responses: [[ListeningPort]], gate: DispatchSemaphore? = nil) {
        self.responses = responses
        self.gate = gate
    }

    var count: Int { lock.withLock { calls } }

    func sweep(_ owners: [pid_t: String], _ remembered: [PIDIdentity: String], _ port: Int?) -> PortSweepResult {
        lock.lock()
        calls += 1
        let ports = responses.count > 1 ? responses.removeFirst() : (responses.first ?? [])
        lock.unlock()
        gate?.wait()
        return PortSweepResult(ports: ports, attributions: [:], liveIdentities: [])
    }
}

@MainActor
final class ListeningPortModelTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentboard-portmodel/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeModel(
        db: AppDatabase,
        spy: SweepSpy,
        shellPIDs: [String: pid_t] = [:],
        boardServerPort: Int? = nil
    ) -> ListeningPortModel {
        ListeningPortModel(
            db: db,
            ledger: PIDSessionLedger(url: directory.appendingPathComponent("owners.json")),
            boardServerPort: { boardServerPort },
            shellConsolePIDs: { shellPIDs },
            agentPIDs: { [:] },
            sweep: spy.sweep
        )
    }

    private func port(_ number: Int, pid: pid_t, session: String?, source: PortAttributionSource? = nil) -> ListeningPort {
        ListeningPort(port: number, pid: pid, command: "node", sessionId: session, source: source)
    }

    private func waitUntil(
        _ description: String, timeout: TimeInterval = 5, _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await _Concurrency.Task.sleep(for: .milliseconds(20))
        }
        XCTFail("timed out waiting for \(description)")
    }

    func testAManualRefreshSweepsAgainAndPublishesTheChangedList() async throws {
        let db = try AppDatabase.inMemory()
        let spy = SweepSpy(responses: [
            [port(3000, pid: 100, session: nil)],
            [port(3000, pid: 100, session: nil), port(5173, pid: 101, session: nil)],
        ])
        let model = makeModel(db: db, spy: spy)

        await model.refreshAndWait()
        XCTAssertEqual(model.ports.map(\.port), [3000])
        let first = try XCTUnwrap(model.sweptAt)

        await model.refreshAndWait()

        XCTAssertEqual(spy.count, 2)
        XCTAssertEqual(model.ports.map(\.port), [3000, 5173])
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(model.sweptAt), first)
    }

    func testASecondRefreshWhileOneIsInFlightJoinsItRatherThanSweepingAgain() async throws {
        let db = try AppDatabase.inMemory()
        let gate = DispatchSemaphore(value: 0)
        let spy = SweepSpy(responses: [[port(3000, pid: 100, session: nil)]], gate: gate)
        let model = makeModel(db: db, spy: spy)

        model.refresh()
        try await waitUntil("the first sweep to start") { spy.count == 1 }
        model.refresh()
        model.refresh()
        XCTAssertTrue(model.isSweeping)

        gate.signal()
        try await waitUntil("the sweep to finish") { !model.isSweeping }

        XCTAssertEqual(spy.count, 1, "a refresh started a second sweep while one was in flight")
        XCTAssertEqual(model.ports.map(\.port), [3000])
    }

    /// Both surfaces read the one array. Letting the sidebar panel and the Status pane sweep
    /// independently would double the cost and let them disagree between ticks.
    func testTheGlobalListAndAProjectFilterComeFromTheSameSweep() async throws {
        let db = try AppDatabase.inMemory()
        let mine = try ProjectStore(db).register(
            name: "Mine", repoPath: "/mine", baseBranch: "main", worktreeRoot: "/w/mine", memoryDir: nil
        )
        let theirs = try ProjectStore(db).register(
            name: "Theirs", repoPath: "/theirs", baseBranch: "main", worktreeRoot: "/w/theirs", memoryDir: nil
        )
        let here = try session(db, project: mine, id: "session-mine", title: "Run the dev server")
        let there = try session(db, project: theirs, id: "session-theirs", title: "Something else")
        let spy = SweepSpy(responses: [[
            port(3000, pid: 100, session: here),
            port(4000, pid: 101, session: there),
            port(9999, pid: 102, session: nil),
        ]])
        let model = makeModel(db: db, spy: spy)

        await model.refreshAndWait()
        let global = model.ports
        let filtered = model.ports(inProject: mine.id)

        XCTAssertEqual(spy.count, 1, "reading both surfaces swept twice")
        XCTAssertEqual(global.map(\.port), [3000, 4000, 9999])
        XCTAssertEqual(filtered.map(\.port), [3000])
        XCTAssertEqual(filtered.first?.taskTitle, "Run the dev server")
        XCTAssertEqual(global.first { $0.port == 9999 }?.ownership, .unattributed)
    }

    func testAnOrphanCarriesItsEndedSessionsTaskTitle() async throws {
        let db = try AppDatabase.inMemory()
        let project = try ProjectStore(db).register(
            name: "Mine", repoPath: "/mine", baseBranch: "main", worktreeRoot: "/w/mine", memoryDir: nil
        )
        let ended = try session(
            db, project: project, id: "session-ended", title: "Ship the dev server", state: .completed
        )
        let spy = SweepSpy(responses: [[port(3000, pid: 100, session: ended, source: .ledger)]])
        let model = makeModel(db: db, spy: spy)

        await model.refreshAndWait()

        let row = try XCTUnwrap(model.ports.first)
        XCTAssertEqual(row.ownership, .orphaned)
        XCTAssertEqual(row.sessionId, "session-ended")
        XCTAssertEqual(row.taskTitle, "Ship the dev server")
        XCTAssertEqual(row.projectName, "Mine")
        XCTAssertEqual(row.pid, 100, "the stop path needs the pid")
    }

    func testAnOrphanWhoseRowsAreGoneStillRendersWithItsPidAndCommand() async throws {
        let db = try AppDatabase.inMemory()
        let spy = SweepSpy(responses: [[port(3000, pid: 100, session: "session-purged", source: .ledger)]])
        let model = makeModel(db: db, spy: spy)

        await model.refreshAndWait()

        let row = try XCTUnwrap(model.ports.first)
        XCTAssertEqual(row.ownership, .orphaned)
        XCTAssertEqual(row.sessionId, "session-purged")
        XCTAssertNil(row.taskTitle)
        XCTAssertNil(row.projectName)
        XCTAssertNil(row.projectId)
        XCTAssertEqual(row.command, "node")
    }

    func testAShellConsolesPortIsAttributedToItsProjectWithNoSession() async throws {
        let db = try AppDatabase.inMemory()
        let project = try ProjectStore(db).register(
            name: "Mine", repoPath: "/mine", baseBranch: "main", worktreeRoot: "/w/mine", memoryDir: nil
        )
        let key = PortOwnerKey.shellConsole(projectId: project.id).encoded
        let spy = SweepSpy(responses: [[port(8080, pid: 100, session: key)]])
        let model = makeModel(db: db, spy: spy, shellPIDs: [project.id: 55])

        await model.refreshAndWait()

        let row = try XCTUnwrap(model.ports.first)
        XCTAssertEqual(row.ownership, .shellConsole)
        XCTAssertNil(row.sessionId)
        XCTAssertEqual(row.projectId, project.id)
        XCTAssertEqual(model.ports(inProject: project.id).map(\.port), [8080])
    }

    /// Listening ports are live system state, so none of this belongs in the board's database and
    /// none of it added a migration. `PIDSessionLedger` is the one thing that outlives the process
    /// and it is a JSON file.
    func testNothingHereWritesToTheDatabaseAndNoMigrationWasAdded() async throws {
        let db = try AppDatabase.inMemory()
        let project = try ProjectStore(db).register(
            name: "Mine", repoPath: "/mine", baseBranch: "main", worktreeRoot: "/w/mine", memoryDir: nil
        )
        let live = try session(db, project: project, id: "session-live", title: "Run it")

        let applied = try migrationIdentifiers(db)
        XCTAssertFalse(applied.isEmpty, "the migration list could not be read, so the check below is vacuous")
        XCTAssertFalse(applied.contains(where: namesPortsOrPIDs), "a port migration was registered: \(applied)")
        let before = try rowCounts(db)
        XCTAssertFalse(before.keys.contains(where: namesPortsOrPIDs), "a port table exists: \(before.keys.sorted())")
        let spy = SweepSpy(responses: [[
            port(3000, pid: 100, session: live),
            port(4000, pid: 101, session: "session-unknown", source: .ledger),
            port(5000, pid: 102, session: nil),
        ]])
        let model = makeModel(db: db, spy: spy, shellPIDs: [project.id: 55])

        await model.refreshAndWait()
        await model.refreshAndWait()

        XCTAssertEqual(model.ports.count, 3)
        XCTAssertEqual(try rowCounts(db), before, "a sweep wrote to the database")
        XCTAssertEqual(try migrationIdentifiers(db), applied)
    }

    /// Whole-word, because `report` contains "port" and a substring check passes vacuously.
    private func namesPortsOrPIDs(_ name: String) -> Bool {
        let words = Set(name.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        return !words.isDisjoint(with: ["port", "ports", "pid", "pids", "listening", "socket"])
    }

    private func migrationIdentifiers(_ db: AppDatabase) throws -> [String] {
        try db.reader.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        }
    }

    private func rowCounts(_ db: AppDatabase) throws -> [String: Int] {
        try db.reader.read { db in
            let tables = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '%_fts%'"
            )
            return try tables.reduce(into: [String: Int]()) { result, table in
                result[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(table)\"") ?? 0
            }
        }
    }

    @discardableResult
    private func session(
        _ db: AppDatabase,
        project: Project,
        id: String,
        title: String,
        state: SessionState = .running
    ) throws -> String {
        let task = try TaskStore(db).create(
            projectId: project.id, title: title, body: nil, acceptance: nil, priority: nil,
            column: .running, origin: .human, epicId: nil
        )
        try SessionStore(db).insert(
            AgentSession(
                sessionId: id, projectId: project.id, taskId: task.id, role: .worker,
                cwd: "/tmp", state: state,
                endedAt: state == .completed ? .nowMillis : nil
            )
        )
        return id
    }
}
