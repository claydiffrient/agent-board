import AgentBoardCore
import AppKit
import Observation
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

    /// Choosing a type edits the inspector's draft, the one Save writes; switching tasks keeps it.
    func testTheInspectorTypePickerShowsTheTaskTypeAndEditsItsDraft() throws {
        let task = try makeTask("Parser checks", type: .code)
        let other = try makeTask("Lint cleanup", type: nil)
        let selection = Selection(task: task)
        let drafts = TaskDraftCache()
        let mount = OffscreenMount(
            SelectedInspector(selection: selection, allTasks: [task, other], drafts: drafts).environment(renderEnvironment(db: db)),
            size: CGSize(width: 420, height: 1000)
        )
        defer { mount.close() }

        let expected = ["Default"] + TaskType.allCases.map(\.label)
        let isTypePicker: (NSPopUpButton) -> Bool = { $0.itemTitles == expected }
        settle { views(NSPopUpButton.self, in: mount.host).contains(where: isTypePicker) }
        let picker = try XCTUnwrap(
            views(NSPopUpButton.self, in: mount.host).first(where: isTypePicker),
            "no pop-up lists \(expected): \(views(NSPopUpButton.self, in: mount.host).map(\.itemTitles))"
        )
        XCTAssertEqual(picker.titleOfSelectedItem, "Code")

        picker.menu?.performActionForItem(at: picker.indexOfItem(withTitle: "Plan"))
        selection.task = other
        settle { drafts.draft(for: task.id) != nil }
        XCTAssertEqual(drafts.draft(for: task.id)?.type, .plan)
        XCTAssertEqual(picker.titleOfSelectedItem, "Default", "the other task is Default")
    }

    private func makeTask(_ title: String, type: TaskType?) throws -> BoardTask {
        try TaskStore(db).create(
            projectId: project.id, title: title, body: nil, acceptance: nil,
            priority: nil, column: .ready, origin: .human, epicId: nil, type: type
        )
    }

    private func settle(until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        } while !done() && Date() < deadline
    }

    private func views<V: NSView>(_ type: V.Type, in root: NSView) -> [V] {
        var found: [V] = []
        func walk(_ view: NSView) {
            if let match = view as? V { found.append(match) }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
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

@Observable
private final class Selection {
    var task: BoardTask
    init(task: BoardTask) { self.task = task }
}

private struct SelectedInspector: View {
    let selection: Selection
    let allTasks: [BoardTask]
    let drafts: TaskDraftCache

    var body: some View {
        TaskInspectorView(task: selection.task, allTasks: allTasks, sessions: [], drafts: drafts, onClose: {})
    }
}
