import AgentBoardCore
import Foundation
import XCTest
@testable import AgentBoard

@MainActor
final class ArchiveSweepSupervisorTests: XCTestCase {
    private var fixture: SupervisorFixture!

    override func setUp() async throws {
        fixture = try SupervisorFixture.make()
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    private func setPolicy(_ policy: ArchivePolicy) throws {
        let projects = ProjectStore(fixture.db)
        var settings = try XCTUnwrap(projects.get(fixture.project.id)?.settings)
        settings.archivePolicy = policy
        try projects.updateSettings(fixture.project.id, settings)
    }

    @discardableResult
    private func doneTask(_ title: String, daysInDone: Double) throws -> BoardTask {
        let task = try fixture.tasks.create(
            projectId: fixture.project.id, title: title, body: nil, acceptance: nil, priority: nil,
            column: .done, origin: .human, epicId: nil
        )
        let at = Int64.nowMillis - Int64(daysInDone * Double(ArchiveSweep.millisPerDay))
        try fixture.db.writer.write { db in
            try db.execute(sql: "UPDATE task SET done_at = ? WHERE id = ?", arguments: [at, task.id])
        }
        return try XCTUnwrap(fixture.tasks.get(task.id))
    }

    private func tick() throws -> [String] {
        fixture.supervisor.sweepArchives(try ProjectStore(fixture.db).list())
    }

    private func isArchived(_ id: String) throws -> Bool {
        try XCTUnwrap(fixture.tasks.get(id)).isArchived
    }

    func testTheTickArchivesOnlyWhatIsPastTheAfterDaysThreshold() throws {
        try setPolicy(.afterDays(5))
        let old = try doneTask("old", daysInDone: 12)
        let young = try doneTask("young", daysInDone: 1)
        let running = try fixture.tasks.create(
            projectId: fixture.project.id, title: "running", body: nil, acceptance: nil, priority: nil,
            column: .running, origin: .human, epicId: nil
        )

        XCTAssertEqual(try tick(), [old.id])
        XCTAssertTrue(try isArchived(old.id))
        XCTAssertFalse(try isArchived(young.id))
        XCTAssertFalse(try isArchived(running.id))
    }

    func testTheTickArchivesNothingUnderManual() throws {
        try setPolicy(.manual)
        let ancient = try doneTask("ancient", daysInDone: 365)

        XCTAssertEqual(try tick(), [])
        XCTAssertEqual(try tick(), [])
        XCTAssertFalse(try isArchived(ancient.id))
    }

    func testTheTickArchivesNothingUnderAfterEpicMerge() throws {
        try setPolicy(.afterEpicMerge)
        let ancient = try doneTask("ancient", daysInDone: 365)

        XCTAssertEqual(try tick(), [])
        XCTAssertFalse(try isArchived(ancient.id))
    }

    func testTheTickDoesNotReArchiveAManuallyUnarchivedTask() throws {
        try setPolicy(.afterDays(3))
        let old = try doneTask("old", daysInDone: 40)
        XCTAssertEqual(try tick(), [old.id])

        try fixture.tasks.unarchive(old.id)

        XCTAssertEqual(try tick(), [])
        XCTAssertEqual(try tick(), [])
        XCTAssertFalse(try isArchived(old.id))
    }

    func testRepeatedTicksArchiveEachTaskOnce() throws {
        try setPolicy(.afterDays(1))
        let old = try doneTask("old", daysInDone: 9)

        XCTAssertEqual(try tick(), [old.id])
        let stampedAt = try XCTUnwrap(fixture.tasks.get(old.id)?.archivedAt)
        XCTAssertEqual(try tick(), [])
        XCTAssertEqual(try fixture.tasks.get(old.id)?.archivedAt, stampedAt)
    }

    func testTheSweepRidesTheMeteringTickWithoutASecondTimer() async throws {
        try setPolicy(.afterDays(1))
        let old = try doneTask("old", daysInDone: 9)

        // The supervisor owns exactly one repeating task; the sweep is throttled inside it.
        XCTAssertEqual(WorkerSupervisor.archiveSweepIntervalMillis, 5 * 60 * 1000)
        XCTAssertGreaterThan(
            WorkerSupervisor.archiveSweepIntervalMillis,
            Int64(WorkerSupervisor.meteringInterval.components.seconds * 1000),
            "a day-granularity policy must not run on the 5s metering cadence"
        )
        XCTAssertEqual(try tick(), [old.id])
    }
}
