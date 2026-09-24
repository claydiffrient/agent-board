import AppKit
import SwiftUI
import Vision
import XCTest
@testable import AgentBoard
@testable import AgentBoardCore

/// Reads the Status page's rendered text with Vision OCR over the window-server capture: SwiftUI
/// `Text` leaves no string in the AppKit view tree to assert on.
@MainActor
final class StatusRosterAgentRenderTests: XCTestCase {
    func testAReviewingRosteredSessionShowsItsAgentAndAPlainWorkerDoesNot() throws {
        let db = try AppDatabase.inMemory()
        let project = try ProjectStore(db).register(
            name: "derivita-ui", repoPath: "/tmp/status-roster-\(UUID().uuidString)", baseBranch: "main",
            worktreeRoot: "/tmp/status-roster-worktrees", memoryDir: nil
        )
        let rita = try RosterStore(db).create(name: "Rita", role: "Code reviewer", systemPrompt: "Review.")
        try RosterStore(db).enable(agentId: rita.id, forProject: project.id)
        var settings = project.settings
        settings.reviewLevel = .agent
        settings.reviewAgent = ReviewAgentChoice(id: rita.id, name: rita.name)
        try ProjectStore(db).updateSettings(project.id, settings)

        // Ended inside the grace window, so both rows show and no Elapsed clock keeps repainting.
        let endedAt = Int64.nowMillis - 60_000
        func session(_ id: String, title: String, agent: String?, scope: TokenScope) throws {
            let task = try TaskStore(db).create(
                projectId: project.id, title: title, body: nil, acceptance: nil, priority: nil,
                column: .review, origin: .human, epicId: nil
            )
            try SessionStore(db).insert(AgentSession(
                sessionId: id, projectId: project.id, taskId: task.id, role: .worker, cwd: "/tmp",
                state: .completed, startedAt: endedAt - 60_000, endedAt: endedAt, rosterAgentId: agent
            ))
            let grant = try TokenGrantStore(db).issue(projectId: project.id, scope: scope, taskId: task.id)
            try TokenGrantStore(db).bind(token: grant.token, sessionId: id)
        }
        try session("s-review", title: "Parser checks", agent: rita.id, scope: .reviewer)
        try session("s-plain", title: "Lint cleanup", agent: nil, scope: .worker)

        let mount = OffscreenMount(StatusView(project: project).environment(renderEnvironment(db: db)))
        defer { mount.close() }
        _ = try mount.capture()
        let image = try XCTUnwrap(CGWindowListCreateImage(
            .null, .optionIncludingWindow, CGWindowID(mount.window.windowNumber),
            [.boundsIgnoreFraming, .bestResolution]
        ))
        let lines = try recognizedLines(in: image)

        let reviewRow = try row(containing: "Parser checks", in: lines)
        XCTAssertTrue(reviewRow.contains("Rita"), "reviewer row read as: \(reviewRow)")
        XCTAssertTrue(reviewRow.contains("reviewer"), "reviewer row read as: \(reviewRow)")

        let plainRow = try row(containing: "Lint cleanup", in: lines)
        XCTAssertTrue(plainRow.contains("worker"), "plain row read as: \(plainRow)")
        XCTAssertFalse(plainRow.contains("Rita"), "plain row read as: \(plainRow)")
        XCTAssertFalse(plainRow.contains("reviewer"), "plain row read as: \(plainRow)")

        // OCR misreads the banner sentence on CI's paravirtual display. Read StatusSnapshot.fetch
        // directly instead — the same call observeStatus's ValueObservation makes on every change.
        let snapshot = try db.reader.read { try StatusSnapshot.fetch($0, projectId: project.id) }
        XCTAssertEqual(snapshot.review, .agentReview(agentId: rita.id, agentName: rita.name))
    }

    private struct Line {
        let text: String
        let box: CGRect
    }

    private func recognizedLines(in image: CGImage) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { Line(text: $0.string, box: observation.boundingBox) }
        }
    }

    /// Every line whose vertical centre falls inside the anchor line's band, left to right.
    private func row(containing anchor: String, in lines: [Line]) throws -> String {
        let hit = try XCTUnwrap(
            lines.first { $0.text.contains(anchor) }, "\"\(anchor)\" not found in: \(lines.map(\.text))"
        )
        return lines
            .filter { $0.box.midY > hit.box.minY && $0.box.midY < hit.box.maxY }
            .sorted { $0.box.minX < $1.box.minX }
            .map(\.text)
            .joined(separator: " | ")
    }
}
