import Foundation
import XCTest
@testable import AgentBoardCore

final class CapCheckTests: XCTestCase {
    func testAllowedBelowCap() throws {
        let f = try Fixture.make()
        try f.sessions.insert(f.session("w1"))
        try f.sessions.insert(f.session("w2"))
        XCTAssertEqual(try f.board.canSpawn(projectId: f.project.id), .allowed)
    }

    func testRefusedAtConcurrencyCap() throws {
        let f = try Fixture.make()
        try f.sessions.insert(f.session("w1", state: .running))
        try f.sessions.insert(f.session("w2", state: .idle))
        try f.sessions.insert(f.session("w3", state: .blocked))
        let decision = try CapCheck(f.db).canSpawn(projectId: f.project.id)
        guard case .refused(let reason) = decision else {
            return XCTFail("expected refusal, got \(decision)")
        }
        XCTAssertTrue(reason.contains("3"))
        XCTAssertFalse(decision.isAllowed)
    }

    func testEndedWorkersAndOrchestratorDoNotCount() throws {
        let f = try Fixture.make()
        try f.sessions.insert(f.session("w1", state: .completed))
        try f.sessions.insert(f.session("w2", state: .failed))
        try f.sessions.insert(f.session("w3", state: .stopped))
        try f.sessions.insert(f.session("o1", role: .orchestrator, state: .running))
        XCTAssertEqual(try f.board.canSpawn(projectId: f.project.id), .allowed)
    }

    func testRespectsLoweredCapFromSettings() throws {
        let f = try Fixture.make()
        var settings = ProjectSettings()
        settings.caps.maxConcurrentWorkers = 1
        try f.projects.updateSettings(f.project.id, settings)
        XCTAssertEqual(try f.board.canSpawn(projectId: f.project.id), .allowed)
        try f.sessions.insert(f.session("w1"))
        XCTAssertNotEqual(try f.board.canSpawn(projectId: f.project.id), .allowed)
    }

    func testSessionCeilingCountsEverySession() throws {
        let f = try Fixture.make()
        var settings = ProjectSettings()
        settings.caps.sessionCeiling = 2
        try f.projects.updateSettings(f.project.id, settings)
        try f.sessions.insert(f.session("w1", state: .completed))
        try f.sessions.insert(f.session("w2", state: .stopped))
        guard case .refused(let reason) = try f.board.canSpawn(projectId: f.project.id) else {
            return XCTFail("expected refusal")
        }
        XCTAssertTrue(reason.contains("ceiling"))
    }

    func testUnknownProjectThrows() throws {
        let f = try Fixture.make()
        XCTAssertThrowsError(try f.board.canSpawn(projectId: "nope")) { error in
            XCTAssertEqual(error as? BoardError, .projectNotFound("nope"))
        }
    }
}
