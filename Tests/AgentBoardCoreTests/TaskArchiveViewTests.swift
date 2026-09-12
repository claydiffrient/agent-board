import XCTest
@testable import AgentBoardCore

final class TaskArchiveViewTests: XCTestCase {
    private func task(_ id: String, column: TaskColumn, archivedAt: Int64? = nil) -> BoardTask {
        BoardTask(
            id: id, projectId: "p", epicId: nil, title: id, body: nil, acceptance: nil, priority: nil,
            column: column, ordering: 0, origin: .human, createdAt: 0, updatedAt: 0, archivedAt: archivedAt
        )
    }

    func testArchivableTakesOnlyUnarchivedDoneTasks() {
        let board = [
            task("ready", column: .ready),
            task("done1", column: .done),
            task("review", column: .review),
            task("done2", column: .done),
            task("already", column: .done, archivedAt: 5),
        ]
        XCTAssertEqual(TaskArchive.archivable(board).map(\.id), ["done1", "done2"])
    }

    func testArchivableIsEmptyWhenDoneIsEmptyOrFullyArchived() {
        XCTAssertTrue(TaskArchive.archivable([BoardTask]()).isEmpty)
        XCTAssertTrue(TaskArchive.archivable([task("a", column: .done, archivedAt: 1)]).isEmpty)
        XCTAssertTrue(TaskArchive.archivable([task("a", column: .running)]).isEmpty)
    }

    func testArchivableIgnoresTheArchivedFlagOutsideDone() {
        let reopened = task("reopened", column: .ready, archivedAt: 9)
        XCTAssertTrue(TaskArchive.archivable([reopened]).isEmpty)
    }

    func testPartitionHidesArchivedWhenTheToggleIsOff() {
        let board = [
            task("live", column: .done),
            task("gone", column: .done, archivedAt: 3),
            task("ready", column: .ready),
        ]
        let split = TaskArchive.partition(board, showArchived: false)
        XCTAssertEqual(split.visible.map(\.id), ["live", "ready"])
        XCTAssertEqual(split.hidden.map(\.id), ["gone"])
    }

    func testPartitionShowsEverythingWhenTheToggleIsOn() {
        let board = [
            task("live", column: .done),
            task("gone", column: .done, archivedAt: 3),
        ]
        let split = TaskArchive.partition(board, showArchived: true)
        XCTAssertEqual(split.visible.map(\.id), ["live", "gone"])
        XCTAssertTrue(split.hidden.isEmpty)
    }

    func testPartitionLosesNoTaskAndPreservesOrder() {
        let board = (0..<10).map { task("t\($0)", column: .done, archivedAt: $0.isMultiple(of: 3) ? Int64($0) : nil) }
        for showArchived in [true, false] {
            let split = TaskArchive.partition(board, showArchived: showArchived)
            XCTAssertEqual(split.visible.count + split.hidden.count, board.count)
            XCTAssertEqual(
                Set(split.visible.map(\.id)).union(split.hidden.map(\.id)),
                Set(board.map(\.id))
            )
            XCTAssertEqual(split.visible.map(\.id), board.filter { split.visible.contains($0) }.map(\.id))
        }
    }

    func testPartitionOfAnEmptyBoard() {
        let split = TaskArchive.partition([BoardTask](), showArchived: false)
        XCTAssertTrue(split.visible.isEmpty)
        XCTAssertTrue(split.hidden.isEmpty)
    }

    func testHiddenHalfIsExactlyTheArchivedTasksWhateverTheirColumn() {
        let board = [
            task("archived-done", column: .done, archivedAt: 1),
            task("archived-elsewhere", column: .backlog, archivedAt: 2),
            task("live", column: .backlog),
        ]
        let split = TaskArchive.partition(board, showArchived: false)
        XCTAssertEqual(split.hidden.map(\.id), ["archived-done", "archived-elsewhere"])
        XCTAssertEqual(split.visible.map(\.id), ["live"])
    }

    func testNewestFirstOrdersByArchiveStampDescending() {
        let board = [
            task("old", column: .done, archivedAt: 100),
            task("newest", column: .done, archivedAt: 300),
            task("middle", column: .done, archivedAt: 200),
        ]
        XCTAssertEqual(TaskArchive.newestFirst(board).map(\.id), ["newest", "middle", "old"])
    }

    func testNewestFirstBreaksTiesOnIdSoTheOrderIsStable() {
        let board = [
            task("b", column: .done, archivedAt: 100),
            task("a", column: .done, archivedAt: 100),
        ]
        XCTAssertEqual(TaskArchive.newestFirst(board).map(\.id), ["a", "b"])
    }

    func testButtonTitleCarriesTheCount() {
        XCTAssertEqual(TaskArchive.buttonTitle(count: 0), "Archive Done Tasks")
        XCTAssertEqual(TaskArchive.buttonTitle(count: 1), "Archive 1 Done Task")
        XCTAssertEqual(TaskArchive.buttonTitle(count: 23), "Archive 23 Done Tasks")
    }

    func testConfirmationTitleCarriesTheCount() {
        XCTAssertEqual(TaskArchive.confirmationTitle(count: 1), "Archive 1 done task?")
        XCTAssertEqual(TaskArchive.confirmationTitle(count: 23), "Archive 23 done tasks?")
    }

    func testDoneColumnSaysNothingWhenItHidesNothing() {
        XCTAssertNil(TaskArchive.hiddenNotice(count: 0))
        XCTAssertEqual(TaskArchive.hiddenNotice(count: 1), "1 archived")
        XCTAssertEqual(TaskArchive.hiddenNotice(count: 23), "23 archived")
    }
}

final class ArchivePolicyModeTests: XCTestCase {
    func testDefaultPolicyIsAfterEpicMerge() {
        XCTAssertEqual(ProjectSettings().archivePolicy, .afterEpicMerge)
        XCTAssertEqual(ProjectSettings().archivePolicy.mode, .afterEpicMerge)
    }

    func testOnlyAfterDaysCarriesADayCount() {
        XCTAssertNil(ArchivePolicy.manual.days)
        XCTAssertNil(ArchivePolicy.afterEpicMerge.days)
        XCTAssertEqual(ArchivePolicy.afterDays(30).days, 30)
    }

    func testMakeIgnoresTheDayCountOutsideAfterDays() {
        XCTAssertEqual(ArchivePolicy.make(mode: .manual, days: 30), .manual)
        XCTAssertEqual(ArchivePolicy.make(mode: .afterEpicMerge, days: 30), .afterEpicMerge)
        XCTAssertEqual(ArchivePolicy.make(mode: .afterDays, days: 30), .afterDays(30))
    }

    func testMakeFloorsTheDayCountAtOne() {
        XCTAssertEqual(ArchivePolicy.make(mode: .afterDays, days: 0), .afterDays(1))
        XCTAssertEqual(ArchivePolicy.make(mode: .afterDays, days: -5), .afterDays(1))
    }

    func testModeAndMakeRoundTripEveryPolicy() {
        for policy in [ArchivePolicy.manual, .afterDays(7), .afterEpicMerge] {
            let rebuilt = ArchivePolicy.make(mode: policy.mode, days: policy.days ?? ArchivePolicy.defaultDays)
            XCTAssertEqual(rebuilt, policy)
        }
    }

    func testPickerOffersExactlyThreeModes() {
        XCTAssertEqual(ArchivePolicyMode.allCases, [.manual, .afterDays, .afterEpicMerge])
    }
}
