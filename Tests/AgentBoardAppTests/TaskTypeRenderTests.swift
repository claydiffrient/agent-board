import AgentBoardCore
import AppKit
import SwiftUI
import Vision
import XCTest
@testable import AgentBoard

@MainActor
final class TaskTypeRenderTests: XCTestCase {
    private var db: AppDatabase!
    private var project: Project!

    override func setUp() async throws {
        db = try AppDatabase.inMemory()
        project = try ProjectStore(db).register(
            name: "Demo", repoPath: "/tmp/demo-\(UUID().uuidString)", baseBranch: "main",
            worktreeRoot: "/tmp/demo-worktrees", memoryDir: nil
        )
    }

    /// Read with Vision OCR: SwiftUI `Text` leaves no string in the AppKit view tree.
    func testATypedCardShowsItsTypeAndADefaultCardShowsNone() throws {
        let typed = try makeTask("Parser checks", type: .docs)
        let plain = try makeTask("Lint cleanup", type: nil)
        let cards = VStack(spacing: 24) {
            ForEach([typed, plain]) { task in
                TaskCardView(
                    task: task, epicTitle: nil, activeSession: nil, latestSession: nil, isSelected: false,
                    onAccept: {}, onReopen: {}
                )
            }
        }
        .padding()
        .frame(width: 320)
        let mount = OffscreenMount(cards.environment(renderEnvironment(db: db)), size: CGSize(width: 320, height: 240))
        defer { mount.close() }
        _ = try mount.capture()
        let image = try XCTUnwrap(CGWindowListCreateImage(
            .null, .optionIncludingWindow, CGWindowID(mount.window.windowNumber),
            [.boundsIgnoreFraming, .bestResolution]
        ))
        let lines = try recognizedLines(in: image)

        let typedRow = try row(containing: "Parser checks", in: lines)
        XCTAssertTrue(typedRow.contains("Docs"), "typed card read as: \(typedRow)")
        let plainRow = try row(containing: "Lint cleanup", in: lines)
        for type in TaskType.allCases {
            XCTAssertFalse(plainRow.contains(type.label), "Default card read as: \(plainRow)")
        }
        XCTAssertFalse(plainRow.contains("Default"), "Default card read as: \(plainRow)")
    }

    /// The read half: the inspector's Type picker shows the task's stored type, read with Vision
    /// OCR. On macOS 27, in this offscreen/non-active session, a SwiftUI `Picker` no longer
    /// constructs an `NSPopUpButton` at all — not renamed, not empty, just absent from the AppKit
    /// view tree, even mounted through a real, on-screen, `makeKeyAndOrderFront`-ed window (see the
    /// headless UI verification note). The control still *draws*, though — OCR reads "Code" or
    /// "Default" off the rendered pixels the same way `testATypedCardShowsItsTypeAndADefaultCardShowsNone`
    /// reads a `TaskTypeChip`'s label above.
    ///
    /// The header above also draws a `TaskTypeChip` off `task.type` directly — nothing to do with
    /// the picker or its draft state — and for a `.code` task it reads "Code" too. A first version of
    /// this test asserted `lines.contains("Code")` anywhere on the page and stayed green even with
    /// `TaskInspectorView.apply` mutated to force `draftType = nil`, because the header's chip alone
    /// satisfied it. `typeRow(in:)` isolates the band strictly between the Model row and the
    /// Revert/Save row, where only the picker draws, so the mutation now fails this test as intended.
    func testTheInspectorTypePickerShowsTheTaskType() throws {
        let typed = try makeTask("Parser checks", type: .code)
        let plain = try makeTask("Lint cleanup", type: nil)

        let typedRow = try typeRow(in: try ocrInspector(task: typed, allTasks: [typed]))
        XCTAssertTrue(typedRow.contains("Code"), "the type picker's row did not show Code: \(typedRow)")

        let plainRow = try typeRow(in: try ocrInspector(task: plain, allTasks: [plain]))
        XCTAssertTrue(plainRow.contains("Default"), "the type picker's row did not show Default: \(plainRow)")
        for type in TaskType.allCases {
            XCTAssertFalse(plainRow.contains(type.label), "a default task's picker row read as: \(plainRow)")
        }
    }

    /// The band between the Model row and the Revert/Save row, where only the Type picker draws.
    private func typeRow(in lines: [Line]) throws -> [String] {
        let modelTop = try XCTUnwrap(lines.first { $0.text == "Model" }, "no Model row: \(lines.map(\.text))").box.minY
        let buttonsBottom = try XCTUnwrap(lines.first { $0.text == "Revert" }, "no Revert row: \(lines.map(\.text))").box.maxY
        return lines
            .filter { $0.box.midY > buttonsBottom && $0.box.midY < modelTop }
            .sorted { $0.box.minX < $1.box.minX }
            .map(\.text)
    }

    /// The write half: what `NSPopUpButton.menu?.performActionForItem` used to drive directly is
    /// now exercised one layer down, against `TaskDraftCache` itself — there is no control left to
    /// click. This proves the cache retains and clears a draft correctly; it can no longer prove
    /// that choosing "Plan" in a live picker reaches `retainDrafts`/`drafts.retain` the way
    /// `TaskInspectorView.onChange(of: task.id)` is written to call it.
    func testChoosingATypeRetainsTheDraftAcrossATaskSwitch() throws {
        let task = try makeTask("Parser checks", type: .code)
        let other = try makeTask("Lint cleanup", type: nil)
        let drafts = TaskDraftCache()
        let savedDraft = TaskDraft(body: "", acceptance: "", model: nil, type: .code)
        let editedDraft = TaskDraft(body: "", acceptance: "", model: nil, type: .plan)

        drafts.retain(editedDraft, for: task.id, ifDifferentFrom: savedDraft)
        XCTAssertEqual(drafts.draft(for: task.id)?.type, .plan, "the edited type did not survive in the cache")
        XCTAssertNil(drafts.draft(for: other.id), "a draft leaked onto a task nobody edited")

        drafts.retain(savedDraft, for: task.id, ifDifferentFrom: savedDraft)
        XCTAssertNil(drafts.draft(for: task.id), "reverting to the saved type should clear the retained draft")
    }

    private func ocrInspector(task: BoardTask, allTasks: [BoardTask]) throws -> [Line] {
        let view = TaskInspectorView(task: task, allTasks: allTasks, sessions: [], drafts: TaskDraftCache(), onClose: {})
        let mount = OffscreenMount(view.environment(renderEnvironment(db: db)), size: CGSize(width: 420, height: 1000))
        defer { mount.close() }
        _ = try mount.capture()
        let image = try XCTUnwrap(CGWindowListCreateImage(
            .null, .optionIncludingWindow, CGWindowID(mount.window.windowNumber),
            [.boundsIgnoreFraming, .bestResolution]
        ))
        return try recognizedLines(in: image)
    }

    private func makeTask(_ title: String, type: TaskType?) throws -> BoardTask {
        try TaskStore(db).create(
            projectId: project.id, title: title, body: nil, acceptance: nil,
            priority: nil, column: .ready, origin: .human, epicId: nil, type: type
        )
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
