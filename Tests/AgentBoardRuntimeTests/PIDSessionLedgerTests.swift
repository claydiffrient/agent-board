import AgentBoardRuntime
import Darwin
import Foundation
import XCTest

final class PIDSessionLedgerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentboard-pidledger/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private var url: URL { directory.appendingPathComponent("owners.json") }

    private func identity(_ pid: pid_t, _ started: Int64) -> PIDIdentity {
        PIDIdentity(pid: pid, startedAtMicros: started)
    }

    /// The whole reason the ledger is a file: an orphaned dev server outlives the app that launched
    /// its session, and a second launch has to still know whose it was.
    func testARecordedOwnerSurvivesTheProcessThatWroteIt() {
        let live: Set<PIDIdentity> = [identity(4242, 111), identity(9, 222)]
        PIDSessionLedger(url: url).record(
            attributions: [identity(4242, 111): "session-a"], liveIdentities: live
        )

        XCTAssertEqual(PIDSessionLedger(url: url).remembered(), [identity(4242, 111): "session-a"])
    }

    /// Pid reuse is what makes a stale ledger wrong rather than merely incomplete, so the start time
    /// has to be part of the key and not a stored aside.
    func testAReusedPidWithADifferentStartTimeIsNotTheSameProcess() {
        let ledger = PIDSessionLedger(url: url)
        ledger.record(
            attributions: [identity(4242, 111): "session-a"],
            liveIdentities: [identity(4242, 111)]
        )

        let remembered = ledger.remembered()
        XCTAssertEqual(remembered[identity(4242, 111)], "session-a")
        XCTAssertNil(remembered[identity(4242, 999)], "a reused pid claimed another session's socket")
    }

    /// The prune is what bounds the file and what a reboot rides: afterwards no recorded identity
    /// is live, so the first sweep empties it without anything having to age entries out.
    func testEntriesWhoseProcessIsGoneArePrunedOnTheNextRecord() {
        let ledger = PIDSessionLedger(url: url)
        ledger.record(
            attributions: [identity(10, 1): "a", identity(11, 2): "b"],
            liveIdentities: [identity(10, 1), identity(11, 2)]
        )
        XCTAssertEqual(ledger.remembered().count, 2)

        ledger.record(attributions: [:], liveIdentities: [identity(11, 2)])

        XCTAssertEqual(ledger.remembered(), [identity(11, 2): "b"])
        XCTAssertEqual(PIDSessionLedger(url: url).remembered(), [identity(11, 2): "b"])
    }

    func testAnAbsentFileReadsAsAnEmptyLedgerRatherThanFailing() {
        XCTAssertEqual(PIDSessionLedger(url: url).remembered(), [:])
    }
}

/// The measured claim this whole design rests on: once the chain is broken no walk recovers the
/// session, and a remembered `(pid, start time)` is the only thing that can.
final class OrphanAttributionTests: XCTestCase {
    private var tree: ProcessTreeFixture?
    private var directory: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessTreeFixture.isSupported, "no /usr/bin/python3 to hold a socket")
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentboard-orphan/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tree = try ProcessTreeFixture()
    }

    override func tearDown() {
        tree?.tearDown()
        tree = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testALedgerWrittenWhileTheChainHeldAttributesTheOrphanAfterItBreaks() throws {
        let tree = try XCTUnwrap(self.tree)
        let ledger = PIDSessionLedger(url: directory.appendingPathComponent("owners.json"))

        let first = ListeningPortSweep.sweepResult(
            sessionPIDs: [tree.topPID: "session-top"], boardServerPort: nil
        )
        ledger.record(attributions: first.attributions, liveIdentities: first.liveIdentities)
        let live = try XCTUnwrap(first.ports.first { $0.pid == tree.leafPID })
        XCTAssertEqual(live.sessionId, "session-top")
        XCTAssertEqual(live.source, .liveChain)

        try tree.orphanTheLeaf()

        // The session's own pid is gone from the owner map, exactly as it is once a session ends.
        let after = ListeningPortSweep.sweepResult(
            sessionPIDs: [:], remembered: ledger.remembered(), boardServerPort: nil
        )
        let orphan = try XCTUnwrap(after.ports.first { $0.pid == tree.leafPID })
        XCTAssertEqual(orphan.port, tree.port)
        XCTAssertEqual(orphan.sessionId, "session-top")
        XCTAssertEqual(orphan.source, .ledger)
        XCTAssertEqual(ProcessTable.current().entries[tree.leafPID]?.ppid, 1)
    }

    func testWithoutTheLedgerTheSameOrphanIsUnattributed() throws {
        let tree = try XCTUnwrap(self.tree)
        try tree.orphanTheLeaf()

        let after = ListeningPortSweep.sweepResult(
            sessionPIDs: [:], remembered: [:], boardServerPort: nil
        )

        let orphan = try XCTUnwrap(after.ports.first { $0.pid == tree.leafPID })
        XCTAssertNil(orphan.sessionId)
        XCTAssertNil(orphan.source)
    }

    /// A remembered pid only gets a say once the chain cannot answer, so a live session always wins
    /// over a stale claim about the same pid.
    func testTheLiveChainOutranksTheLedger() throws {
        let tree = try XCTUnwrap(self.tree)
        let stale = try XCTUnwrap(ProcessTable.current().identity(of: tree.leafPID))

        let result = ListeningPortSweep.sweepResult(
            sessionPIDs: [tree.topPID: "session-top"],
            remembered: [stale: "someone-else"],
            boardServerPort: nil
        )

        let row = try XCTUnwrap(result.ports.first { $0.pid == tree.leafPID })
        XCTAssertEqual(row.sessionId, "session-top")
        XCTAssertEqual(row.source, .liveChain)
    }

    /// Recording only the listener would lose the socket the moment `npm` restarted `node` under a
    /// surviving shell, so every pid walked through is recorded.
    func testEveryProcessOnAnAttributedChainIsRecordedNotJustTheListener() throws {
        let tree = try XCTUnwrap(self.tree)

        let result = ListeningPortSweep.sweepResult(
            sessionPIDs: [tree.topPID: "session-top"], boardServerPort: nil
        )

        let table = ProcessTable.current()
        for pid in [tree.leafPID, tree.middlePID, tree.topPID] {
            let identity = try XCTUnwrap(table.identity(of: pid))
            XCTAssertEqual(result.attributions[identity], "session-top", "pid \(pid) was not recorded")
        }
    }
}
