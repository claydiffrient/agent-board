import XCTest
@testable import AgentBoard

/// The half of quitting that is not AppKit: what happens to the control when an attempt comes back
/// instead of ending the process. `QuitProbeTests` covers the AppKit half against the real binary.
@MainActor
final class AppQuitTests: XCTestCase {
    func testASheetThatNeverDetachesIsReportedAndNothingIsTerminated() async {
        let quitter = AppQuit(
            sheetedWindows: { ["Shut Down"] }, terminate: { XCTFail("terminated with a sheet up") },
            sleep: { _ in await _Concurrency.Task.yield() }
        )
        quitter.requestQuit()
        await settle(until: { quitter.refusal != nil })
        XCTAssertEqual(
            quitter.refusal,
            "“Shut Down” is still showing a sheet, and macOS will not quit an app while one is "
                + "open. Close it and quit again. The shutdown orders still stand in the meantime."
        )
    }

    /// The defect this fixes: the first attempt failed and the control was dead from then on.
    func testARefusedAttemptLeavesTheControlUsable() async {
        var sheets = ["Shut Down"]
        var terminated = 0
        let quitter = AppQuit(
            sheetedWindows: { sheets }, terminate: { terminated += 1 },
            sleep: { _ in await _Concurrency.Task.yield() }
        )

        quitter.requestQuit()
        await settle(until: { quitter.refusal != nil })
        XCTAssertEqual(terminated, 0)

        sheets = []
        quitter.requestQuit()
        await settle(until: { terminated > 0 })
        XCTAssertEqual(terminated, 1, "a second attempt after a refusal did nothing")
        XCTAssertNil(quitter.refusal, "the stale refusal survived the attempt that cleared it")
    }

    /// `NSApplication.terminate` returns normally whether or not it worked, so an attempt that
    /// leaves the process alive has to be noticed and said out loud rather than assumed to be
    /// in flight forever.
    func testATerminationThatNeverLandsIsReportedAndRetried() async {
        var terminated = 0
        let quitter = AppQuit(
            sheetedWindows: { [] }, terminate: { terminated += 1 },
            sleep: { _ in await _Concurrency.Task.yield() }
        )

        quitter.requestQuit()
        await settle(until: { quitter.refusal != nil })
        XCTAssertEqual(terminated, 1)
        XCTAssertEqual(
            quitter.refusal,
            "macOS did not quit Agent Board when it was asked to. Nothing was undone by the "
                + "attempt — the shutdown orders still stand — so quitting again, or from the Agent "
                + "Board menu, is safe."
        )

        quitter.dismissRefusal()
        quitter.requestQuit()
        await settle(until: { terminated > 1 })
        XCTAssertEqual(terminated, 2)
    }

    /// A sheet on its way out is the normal case: it detaches a turn or two after the dismissal.
    func testAnAttemptWaitsForTheDismissedSheetToDetach() async {
        var polls = 0
        var terminated = 0
        let quitter = AppQuit(
            sheetedWindows: {
                polls += 1
                return polls < 3 ? ["Shut Down"] : []
            },
            terminate: { terminated += 1 },
            sleep: { _ in await _Concurrency.Task.yield() }
        )
        quitter.requestQuit()
        await settle(until: { terminated > 0 })
        XCTAssertEqual(terminated, 1)
        XCTAssertNil(quitter.refusal)
    }

    func testASecondRequestWhileOneIsInFlightIsNotADoubleTerminate() async {
        var terminated = 0
        let quitter = AppQuit(
            sheetedWindows: { [] }, terminate: { terminated += 1 },
            sleep: { _ in await _Concurrency.Task.yield() }
        )
        quitter.requestQuit()
        quitter.requestQuit()
        await settle(until: { quitter.refusal != nil })
        XCTAssertEqual(terminated, 1)
    }

    private func settle(until done: () -> Bool, turns: Int = 5_000) async {
        for _ in 0..<turns where !done() { await _Concurrency.Task.yield() }
    }
}
