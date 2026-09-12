import XCTest
@testable import AgentBoardRuntime

/// Every case writes its own fixture; the real `~/.claude.json` is never opened.
final class AccountUsageTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("account-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func fixture(_ contents: String) throws -> URL {
        let url = directory.appendingPathComponent("claude.json")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The shape observed in `~/.claude.json` on 2026-09-12, other windows left in place.
    private static let realShape = """
    {
      "numStartups": 412,
      "cachedUsageUtilization": {
        "fetchedAtMs": 1789228352560,
        "accountUuid": "f54499b2-ecca-4128-a40b-81b632281de7",
        "utilization": {
          "five_hour": {
            "utilization": 54,
            "resets_at": "2026-09-12T18:40:00.263555+00:00",
            "limit_dollars": null,
            "used_dollars": null,
            "locked_reason": null
          },
          "seven_day": {
            "utilization": 67,
            "resets_at": "2026-09-14T21:00:00.263579+00:00",
            "limit_dollars": null
          },
          "seven_day_opus": null,
          "seven_day_sonnet": null,
          "nimbus_quill": { "utilization": 0, "resets_at": null },
          "extra_usage": { "is_enabled": true, "used_credits": 2178 },
          "limits": [{ "kind": "session", "percent": 54 }]
        }
      }
    }
    """

    func testParsesBothWindowsFromTheShapeClaudeCodeWrites() throws {
        let snapshot = try XCTUnwrap(AccountUsageReader.read(configAt: fixture(Self.realShape)))

        XCTAssertEqual(snapshot.fiveHour?.percent, 54)
        XCTAssertEqual(snapshot.sevenDay?.percent, 67)
        try XCTAssertEqual(XCTUnwrap(snapshot.fiveHour?.resetsAt).timeIntervalSince1970, 1789238400.263, accuracy: 0.01)
        try XCTAssertEqual(XCTUnwrap(snapshot.sevenDay?.resetsAt).timeIntervalSince1970, 1789419600.263, accuracy: 0.01)
        try XCTAssertEqual(XCTUnwrap(snapshot.fetchedAt).timeIntervalSince1970, 1789228352.560, accuracy: 0.01)
    }

    func testMissingBlockIsAbsentRatherThanZero() throws {
        let url = try fixture(#"{"numStartups": 3, "projects": {}}"#)
        XCTAssertNil(AccountUsageReader.read(configAt: url), "no usage block must not read as 0% used")
    }

    func testMissingUtilizationKeyIsAbsent() throws {
        let url = try fixture(#"{"cachedUsageUtilization": {"fetchedAtMs": 1789228352560}}"#)
        XCTAssertNil(AccountUsageReader.read(configAt: url))
    }

    func testNullFiveHourYieldsOnlyTheSevenDayWindow() throws {
        let url = try fixture("""
        {"cachedUsageUtilization": {"fetchedAtMs": 1789228352560,
          "utilization": {"five_hour": null, "seven_day": {"utilization": 67, "resets_at": null}}}}
        """)
        let snapshot = try XCTUnwrap(AccountUsageReader.read(configAt: url))

        XCTAssertNil(snapshot.fiveHour)
        XCTAssertEqual(snapshot.sevenDay?.percent, 67)
        XCTAssertNil(snapshot.sevenDay?.resetsAt)
    }

    func testMalformedFileReturnsNilRatherThanThrowing() throws {
        let url = try fixture(#"{"cachedUsageUtilization": {"fetchedAtMs": 178922835"#)
        XCTAssertNil(AccountUsageReader.read(configAt: url))
    }

    func testMissingFileReturnsNil() {
        let url = directory.appendingPathComponent("does-not-exist.json")
        XCTAssertNil(AccountUsageReader.read(configAt: url))
    }

    func testAbsentFetchedAtMsYieldsUnknownAgeRatherThanAWrongOne() throws {
        let url = try fixture("""
        {"cachedUsageUtilization": {"utilization": {"five_hour": {"utilization": 12, "resets_at": null}}}}
        """)
        let snapshot = try XCTUnwrap(AccountUsageReader.read(configAt: url))

        XCTAssertNil(snapshot.fetchedAt)
        XCTAssertNil(snapshot.age(at: .now), "an unknown age must not present as zero")
        XCTAssertTrue(snapshot.isStale(at: .now), "freshness we cannot prove counts as stale")
    }

    func testUtilizationOutsideZeroToOneHundredIsClamped() throws {
        let url = try fixture("""
        {"cachedUsageUtilization": {"fetchedAtMs": 1789228352560,
          "utilization": {"five_hour": {"utilization": 137}, "seven_day": {"utilization": -4}}}}
        """)
        let snapshot = try XCTUnwrap(AccountUsageReader.read(configAt: url))

        XCTAssertEqual(snapshot.fiveHour?.percent, 100)
        XCTAssertEqual(snapshot.sevenDay?.percent, 0)
    }

    func testStalenessBoundary() {
        let fetchedAt = Date(timeIntervalSince1970: 1_789_228_352)
        let snapshot = AccountUsageSnapshot(
            fiveHour: AccountUsageWindow(percent: 54, resetsAt: nil),
            sevenDay: nil,
            fetchedAt: fetchedAt
        )
        let threshold = AccountUsageSnapshot.staleAfter

        XCTAssertFalse(snapshot.isStale(at: fetchedAt.addingTimeInterval(threshold - 1)))
        XCTAssertFalse(snapshot.isStale(at: fetchedAt.addingTimeInterval(threshold)), "exactly at the threshold is not yet stale")
        XCTAssertTrue(snapshot.isStale(at: fetchedAt.addingTimeInterval(threshold + 1)))
    }

    func testStaleAfterIsThirtyMinutes() {
        XCTAssertEqual(AccountUsageSnapshot.staleAfter, 30 * 60)
    }

    func testAgeNeverGoesNegativeForAClockSkewedReading() {
        let fetchedAt = Date(timeIntervalSince1970: 1_789_228_352)
        let snapshot = AccountUsageSnapshot(fiveHour: nil, sevenDay: nil, fetchedAt: fetchedAt)
        XCTAssertEqual(snapshot.age(at: fetchedAt.addingTimeInterval(-500)), 0)
    }
}

final class AccountUsageRefresherTests: XCTestCase {
    func testRefreshRunsOnceThenIsRateLimited() async {
        let calls = CallCounter()
        let refresher = AccountUsageRefresher { _ in
            await calls.increment()
            return true
        }
        let start = Date(timeIntervalSince1970: 1_789_228_352)

        let first = await refresher.refreshIfAllowed(now: start)
        let second = await refresher.refreshIfAllowed(now: start.addingTimeInterval(60))
        let third = await refresher.refreshIfAllowed(now: start.addingTimeInterval(AccountUsageRefresher.minimumInterval))

        XCTAssertTrue(first)
        XCTAssertFalse(second, "a second attempt inside the floor must not spawn")
        XCTAssertTrue(third)
        let count = await calls.value
        XCTAssertEqual(count, 2)
    }

    func testAFailedRefreshStillCountsAgainstTheRateLimit() async {
        let calls = CallCounter()
        let refresher = AccountUsageRefresher { _ in
            await calls.increment()
            return false
        }
        let start = Date(timeIntervalSince1970: 1_789_228_352)

        _ = await refresher.refreshIfAllowed(now: start)
        _ = await refresher.refreshIfAllowed(now: start.addingTimeInterval(30))

        let count = await calls.value
        XCTAssertEqual(count, 1, "a persistent failure must not be able to spawn repeatedly")
    }

    func testConsecutiveFailuresBackOffAndASuccessResetsTheBackoff() async {
        let outcome = Outcome()
        let refresher = AccountUsageRefresher { _ in await outcome.value }
        let start = Date(timeIntervalSince1970: 1_789_228_352)
        let floor = AccountUsageRefresher.minimumInterval

        await outcome.set(false)
        _ = await refresher.refreshIfAllowed(now: start)
        var interval = await refresher.currentInterval
        XCTAssertEqual(interval, floor * 2, accuracy: 0.001, "one failure doubles the wait")

        _ = await refresher.refreshIfAllowed(now: start.addingTimeInterval(floor + 1))
        interval = await refresher.currentInterval
        XCTAssertEqual(interval, floor * 2, accuracy: 0.001, "an attempt inside the doubled wait must not have run")

        _ = await refresher.refreshIfAllowed(now: start.addingTimeInterval(floor * 2 + 1))
        interval = await refresher.currentInterval
        XCTAssertEqual(interval, floor * 4, accuracy: 0.001)

        await outcome.set(true)
        let recovered = await refresher.refreshIfAllowed(now: start.addingTimeInterval(floor * 100))
        interval = await refresher.currentInterval
        XCTAssertTrue(recovered)
        XCTAssertEqual(interval, floor, accuracy: 0.001, "a success returns to the floor")
    }

    func testBackoffIsCapped() async {
        let refresher = AccountUsageRefresher { _ in false }
        var now = Date(timeIntervalSince1970: 1_789_228_352)
        for _ in 0..<20 {
            now = now.addingTimeInterval(await refresher.currentInterval + 1)
            _ = await refresher.refreshIfAllowed(now: now)
        }
        let interval = await refresher.currentInterval
        let cap = AccountUsageRefresher.minimumInterval * pow(2, Double(AccountUsageRefresher.maximumBackoffMultiplier))
        XCTAssertEqual(interval, cap, accuracy: 0.001)
    }
}

private actor Outcome {
    private(set) var value = true
    func set(_ newValue: Bool) { value = newValue }
}

private actor CallCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
