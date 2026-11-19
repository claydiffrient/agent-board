import AgentBoardCore
import AppKit
import SwiftUI
import Vision
import XCTest
@testable import AgentBoard

/// SPEC §10, Pending reviews: a pull request fix round's row offers no Accept, and names its watch's
/// state and parked reason instead (§13.1).
@MainActor
final class FixRoundReviewRowRenderTests: XCTestCase {
    func testAFixRoundRowShowsItsParkedWatchAndNoAcceptWhileAnOrdinaryRowKeepsAccept() throws {
        let db = try AppDatabase.inMemory()
        let project = try ProjectStore(db).register(
            name: "Demo", repoPath: "/tmp/fixround-\(UUID().uuidString)", baseBranch: "main",
            worktreeRoot: "/tmp/fixround-worktrees", memoryDir: nil
        )
        let watch = try PRWatchStore(db).upsert(projectId: project.id, snapshot: PRSnapshot(
            repoOwner: "example-org", repoName: "app", number: 42,
            url: "https://github.com/example-org/app/pull/42", title: "Add a widget",
            headRef: "feature/widget", headOid: "abc123", baseRef: "main"
        ))
        let tasks = TaskStore(db)
        let round = try tasks.create(
            projectId: project.id, title: "Zebra round fixes", body: nil, acceptance: nil, priority: nil,
            column: .review, origin: .fixRound, epicId: nil
        )
        _ = try tasks.create(
            projectId: project.id, title: "Walrus parser", body: nil, acceptance: nil, priority: nil,
            column: .review, origin: .human, epicId: nil
        )
        try db.writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO pr_round (watch_id, number, base_head_oid, outcome, started_at, fix_task_id)
                VALUES (?, 1, 'abc123', 'check_unavailable', 0, ?)
                """,
                arguments: [watch.id, round.id]
            )
            try db.execute(
                sql: "UPDATE pr_watch SET state = 'parked', round = 1, parked_reason = ? WHERE id = ?",
                arguments: ["Round 1's commit is unpushed", watch.id]
            )
        }

        let lines = try ocr(ApprovalsSidebar(project: project), db: db, size: CGSize(width: 340, height: 900))
        let fixRow = try row("Zebra", in: lines)
        let ordinaryRow = try row("Walrus", in: lines)

        XCTAssertFalse(fixRow.contains("accept"), "fix-round row read as: \(fixRow)")
        XCTAssertFalse(fixRow.contains("reopen"), "fix-round row read as: \(fixRow)")
        XCTAssertTrue(fixRow.contains("parked"), "fix-round row read as: \(fixRow)")
        XCTAssertTrue(fixRow.contains("unpushed"), "fix-round row read as: \(fixRow)")
        XCTAssertTrue(fixRow.contains("show pu"), "fix-round row read as: \(fixRow)")
        XCTAssertTrue(ordinaryRow.contains("accept"), "ordinary row read as: \(ordinaryRow)")
    }

    /// Recognized lines top to bottom. SwiftUI `Text` leaves no string in the AppKit view tree.
    private func ocr(_ view: some View, db: AppDatabase, size: CGSize) throws -> [String] {
        let mount = OffscreenMount(view.environment(renderEnvironment(db: db)), size: size)
        defer { mount.close() }
        _ = try mount.capture()
        let image = try XCTUnwrap(CGWindowListCreateImage(
            .null, .optionIncludingWindow, CGWindowID(mount.window.windowNumber),
            [.boundsIgnoreFraming, .bestResolution]
        ))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? [])
            .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
            .compactMap { $0.topCandidates(1).first?.string }
    }

    /// Lowercased, with I, l and 1 made one character: the CI runner's OCR confuses them.
    private func fold(_ text: String) -> String {
        String(text.lowercased().map { "i1".contains($0) ? "l" : $0 })
    }

    /// From the row's title to the next row's title or the next section header.
    private func row(_ title: String, in lines: [String]) throws -> String {
        let folded = lines.map(fold)
        let from = try XCTUnwrap(folded.firstIndex { $0.contains(fold(title)) }, "\"\(title)\" not found in: \(lines)")
        let stops = ["zebra", "walrus", "proposals"].map(fold)
        let to = folded[(from + 1)...].firstIndex { line in stops.contains { line.contains($0) } } ?? folded.endIndex
        return folded[from..<to].joined(separator: "\n")
    }
}
