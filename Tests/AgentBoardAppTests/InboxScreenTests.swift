import AgentBoardCore
import AppKit
import GRDB
import SwiftUI
import Vision
import XCTest
@testable import AgentBoard

/// SPEC §10, Inbox: a row's Answer zone records a ruling and nothing else, and says so.
@MainActor
final class InboxScreenTests: XCTestCase {
    private var db: AppDatabase!
    private var project: Project!

    override func setUp() async throws {
        db = try AppDatabase.inMemory()
        project = try ProjectStore(db).register(
            name: "Demo", repoPath: "/tmp/demo-\(UUID().uuidString)", baseBranch: "main",
            worktreeRoot: "/tmp/demo-worktrees", memoryDir: nil
        )
    }

    private func blockedTask(_ title: String = "Wire the parser") throws -> InboxItem {
        let task = try TaskStore(db).create(
            projectId: project.id, title: title, body: nil, acceptance: nil, priority: nil,
            column: .running, origin: .human, epicId: nil
        )
        try SessionStore(db).insert(AgentSession(
            sessionId: "w-\(task.id)", projectId: project.id, taskId: task.id, role: .worker, cwd: "/tmp", state: .running
        ))
        _ = try Board(db).block(taskId: task.id, sessionId: "w-\(task.id)", reason: "May I drop the cache?", source: .worker)
        return try XCTUnwrap(try InboxStore(db).items().first { $0.subjectId == task.id })
    }

    func testARowShowsTheCaptionAndNoVerdictIsTheDefaultButton() throws {
        let item = try blockedTask()
        let context = try InboxRowContext.load(db, item: item)
        XCTAssertEqual(context.verdicts(for: item), [.proceed, .instead, .hold])

        let lines = try ocr(InboxRow(item: item, context: context).frame(width: 640))
        let text = fold(lines.joined(separator: " "))
        for word in ["recorded", "ruling", "nothing", "pushed", "merged", "closed"] {
            XCTAssertTrue(text.contains(fold(word)), "\"\(word)\" not read; OCR: \(lines)")
        }

        let control = Button("Default") {}.keyboardShortcut(.defaultAction).padding()
        XCTAssertGreaterThan(
            try accentPixels(control), 200,
            "a default button must read as accent-filled here, or the zero below proves nothing"
        )
        XCTAssertEqual(try accentPixels(InboxRow(item: item, context: context).frame(width: 640)), 0)
    }

    func testAVerdictWritesOneRulingAndChangesNoApprovalReplyOrTaskColumn() async throws {
        let item = try blockedTask()
        try seedOtherSurfaces()
        let context = try InboxRowContext.load(db, item: item)
        let before = try snapshot()
        let rulingsBefore = try rulingCount()

        try await InboxAnswering(db: db, supervisor: StubSupervisor())
            .answer(.proceed, to: item, context: context, note: "")

        let rulingsAfter = try rulingCount()
        XCTAssertEqual(rulingsAfter, rulingsBefore + 1)
        let ruling = try XCTUnwrap(try RulingStore(db).standing(.task(item.subjectId)).first)
        XCTAssertEqual(ruling.verdict, .proceed)
        XCTAssertEqual(ruling.questionAt, item.questionAt)
        let after = try snapshot()
        XCTAssertEqual(after, before)
    }

    private func rulingCount() throws -> Int {
        try db.reader.read { try Ruling.fetchCount($0) }
    }

    private func seedOtherSurfaces() throws {
        let other = try TaskStore(db).create(
            projectId: project.id, title: "Ship it", body: nil, acceptance: nil, priority: nil,
            column: .review, origin: .human, epicId: nil
        )
        _ = try ApprovalStore(db).create(
            projectId: project.id, kind: .spawn, taskId: other.id, epicId: nil, requestedBy: "orch", reason: "Go"
        )
        let projectId = project.id
        try db.writer.write { db in
            try db.execute(sql: """
                INSERT INTO pr_watch (id, project_id, repo_owner, repo_name, number, url, title, head_ref, head_oid,
                  base_ref, state, parked_reason, parked_at, created_at, updated_at)
                VALUES ('w1', ?, 'octo', 'example', 1, 'u', 'Widget', 'h', 'oid', 'main', 'parked', 'Round cap', 500, 0, 0);
                INSERT INTO pr_item (id, watch_id, github_node_id, kind, body, state, verdict, reply_url, round,
                  created_at, updated_at)
                VALUES (7, 'w1', 'n1', 'thread', 'Rename?', 'open', 'answer', 'https://example.invalid/r', 0, 50, 50);
                """, arguments: [projectId])
        }
    }

    private struct Snapshot: Equatable {
        var approvals: [Approval]
        var replyURLs: [String?]
        var tasks: [BoardTask]
    }

    private func snapshot() throws -> Snapshot {
        try db.reader.read { db in
            Snapshot(
                approvals: try Approval.order(Column("id")).fetchAll(db),
                replyURLs: try String?.fetchAll(db, sql: "SELECT reply_url FROM pr_item ORDER BY id"),
                tasks: try BoardTask.order(Column("id")).fetchAll(db)
            )
        }
    }

    private func mount(_ view: some View) throws -> CGImage {
        let mount = OffscreenMount(
            view.environment(\.controlActiveState, .active).environment(renderEnvironment(db: db))
                .background(Color(nsColor: .windowBackgroundColor)),
            size: CGSize(width: 680, height: 520)
        )
        mount.host.appearance = NSAppearance(named: .aqua)
        defer { mount.close() }
        _ = try mount.capture()
        return try XCTUnwrap(CGWindowListCreateImage(
            .null, .optionIncludingWindow, CGWindowID(mount.window.windowNumber),
            [.boundsIgnoreFraming, .bestResolution]
        ))
    }

    /// Strongly blue pixels: a default button's accent fill. The ruling chip's 12% tint does not reach this.
    private func accentPixels(_ view: some View) throws -> Int {
        let image = try mount(view)
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var count = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
            if b - r > 100 && b - g > 40 { count += 1 }
        }
        return count
    }

    private func ocr(_ view: some View) throws -> [String] {
        let image = try mount(view)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? [])
            .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
            .compactMap { $0.topCandidates(1).first?.string }
    }

    /// Lowercased, with I, l and 1 made one character, as the CI runner's OCR confuses them.
    private func fold(_ text: String) -> String {
        String(text.lowercased().map { "i1".contains($0) ? "l" : $0 })
    }
}
