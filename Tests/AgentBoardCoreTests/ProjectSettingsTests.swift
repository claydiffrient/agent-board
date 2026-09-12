import Foundation
import XCTest
@testable import AgentBoardCore

final class ProjectSettingsTests: XCTestCase {
    func testEmptyObjectDecodesToDefaults() throws {
        let settings = try JSONDecoder().decode(ProjectSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings, ProjectSettings())
        XCTAssertEqual(settings.caps.maxConcurrentWorkers, 3)
        XCTAssertNil(settings.caps.maxTokensPerAgent)
        XCTAssertEqual(settings.caps.maxWallClockSeconds, 1800)
        XCTAssertEqual(settings.caps.maxIdleSeconds, 300)
        XCTAssertNil(settings.caps.sessionCeiling)
        XCTAssertFalse(settings.autonomyEnabled)
        XCTAssertNil(settings.autoModeJSON)
        XCTAssertEqual(settings.extraMcpServers, [])
    }

    func testPartialCapsFillMissingKeys() throws {
        let json = #"{"caps":{"maxConcurrentWorkers":1,"sessionCeiling":10},"autonomyEnabled":true}"#
        let settings = try JSONDecoder().decode(ProjectSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.caps.maxConcurrentWorkers, 1)
        XCTAssertEqual(settings.caps.sessionCeiling, 10)
        XCTAssertNil(settings.caps.maxTokensPerAgent)
        XCTAssertTrue(settings.autonomyEnabled)
    }

    func testMalformedJSONFallsBackToDefaults() {
        XCTAssertEqual(ProjectSettings.decode("not json"), ProjectSettings())
    }

    func testEncodeDecodeRoundTrip() throws {
        var settings = ProjectSettings()
        settings.autoModeJSON = #"{"rules":[]}"#
        settings.extraMcpServers = ["mdn", "caniuse"]
        settings.caps.maxIdleSeconds = 60
        XCTAssertEqual(ProjectSettings.decode(settings.encoded()), settings)
    }

    func testTaskColumnOrderAndNeighbors() {
        XCTAssertEqual(TaskColumn.allCases, [.proposed, .backlog, .ready, .running, .review, .done])
        XCTAssertEqual(TaskColumn.proposed.next, .backlog)
        XCTAssertEqual(TaskColumn.review.next, .done)
        XCTAssertNil(TaskColumn.done.next)
        XCTAssertNil(TaskColumn.proposed.previous)
        XCTAssertEqual(TaskColumn.done.index, 5)
        XCTAssertEqual(TaskOrigin.workerProposal.rawValue, "worker_proposal")
    }
}
