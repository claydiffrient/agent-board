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

    /// The read half: the inspector's Type picker shows the task's stored type.
    ///
    /// macOS 26 CI still constructs a real `NSPopUpButton` for this picker; `assertTypePickerShows`
    /// reads `titleOfSelectedItem` off it directly, avoiding the window-server capture race that made
    /// the OCR-only version intermittent (the capture can settle on a frame drawn before the button
    /// painted its title). macOS 27 (this machine) never builds the control at all, so this falls back
    /// to the OCR band below, which stays accurate to the macOS 26 label/value grouping Vision uses
    /// there — see `isLabelLine`/`rowHasWord` and the headless UI verification note.
    func testTheInspectorTypePickerShowsTheTaskType() throws {
        let typed = try makeTask("Parser checks", type: .code)
        let plain = try makeTask("Lint cleanup", type: nil)

        try assertTypePickerShows("Code", for: typed, allTasks: [typed])
        try assertTypePickerShows(
            "Default", for: plain, allTasks: [plain], otherLabelsAbsent: TaskType.allCases.map(\.label)
        )
    }

    /// The Type picker's `NSPopUpButton`, told apart from `ModelPicker`'s own pop-up (also in this
    /// view) by its fixed, distinct item set. Nil on macOS 27, where neither is constructed.
    private func typePickerPopUpButton(in host: NSView) -> NSPopUpButton? {
        let expectedTitles = ["Default"] + TaskType.allCases.map(\.label)
        var found: NSPopUpButton?
        func walk(_ view: NSView) {
            if let button = view as? NSPopUpButton, button.itemTitles == expectedTitles { found = button }
            view.subviews.forEach(walk)
        }
        walk(host)
        return found
    }

    /// One poll loop serves both techniques: a platform that constructs the pop-up button satisfies
    /// `until` as soon as it exists, with no image decode at all; a platform that does not falls
    /// through to the same OCR condition this test used before. Running the pop-up check and the OCR
    /// check as two separate `capture()` calls would settle the window twice on every platform that
    /// takes the OCR path — doubling this test's cost for no benefit there.
    private func assertTypePickerShows(
        _ expected: String, for task: BoardTask, allTasks: [BoardTask], otherLabelsAbsent: [String] = [],
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let view = TaskInspectorView(task: task, allTasks: allTasks, sessions: [], drafts: TaskDraftCache(), onClose: {})
        let mount = OffscreenMount(view.environment(renderEnvironment(db: db)), size: CGSize(width: 420, height: 1000))
        defer { mount.close() }

        var lines: [Line] = []
        _ = try mount.capture(file: file, line: line, until: { _ in
            if self.typePickerPopUpButton(in: mount.host) != nil { return true }
            guard let image = CGWindowListCreateImage(
                .null, .optionIncludingWindow, CGWindowID(mount.window.windowNumber),
                [.boundsIgnoreFraming, .bestResolution]
            ), let recognized = try? self.recognizedLines(in: image) else { return false }
            lines = recognized
            return self.typeRowHasValue(in: recognized)
        })

        if let popUp = typePickerPopUpButton(in: mount.host) {
            XCTAssertEqual(popUp.titleOfSelectedItem, expected, file: file, line: line)
            return
        }
        let row = try typeRow(in: lines)
        XCTAssertTrue(rowHasWord(row, expected), "the type picker's row did not show \(expected): \(row)", file: file, line: line)
        for label in otherLabelsAbsent {
            XCTAssertFalse(rowHasWord(row, label), "the picker row for \(expected) also read as \(label): \(row)", file: file, line: line)
        }
    }

    /// The band between the Model row and the Revert/Save row, where only the Type picker draws.
    private func typeRow(in lines: [Line]) throws -> [String] {
        let modelTop = try XCTUnwrap(
            lines.first { isLabelLine($0.text, label: "Model") }, "no Model row: \(lines.map(\.text))"
        ).box.minY
        let buttonsBottom = try XCTUnwrap(lines.first { $0.text == "Revert" }, "no Revert row: \(lines.map(\.text))").box.maxY
        return bandLines(in: lines, above: buttonsBottom, below: modelTop)
    }

    private func bandLines(in lines: [Line], above buttonsBottom: CGFloat, below modelTop: CGFloat) -> [String] {
        lines
            .filter { $0.box.midY > buttonsBottom && $0.box.midY < modelTop }
            .sorted { $0.box.minX < $1.box.minX }
            .map(\.text)
    }

    /// Whether the Type row already shows a value rather than just the bare "Type" label — used to
    /// poll a capture until the picker's value has actually drawn, not merely until pixels stop
    /// moving. A capture can settle (agreeing frames) while the row still reads only `["Type"]`,
    /// which is exactly what PR #59's CI run hit: `the type picker's row did not show Code: ["Type"]`.
    /// Quiet by design — called every poll iteration, so it must not record a test failure itself;
    /// `typeRow(in:)` above still owns the failure message once the real assertion runs.
    private func typeRowHasValue(in lines: [Line]) -> Bool {
        guard let modelTop = lines.first(where: { isLabelLine($0.text, label: "Model") })?.box.minY,
              let buttonsBottom = lines.first(where: { $0.text == "Revert" })?.box.maxY
        else { return false }
        let row = bandLines(in: lines, above: buttonsBottom, below: modelTop)
        return !row.isEmpty && !row.allSatisfy { $0 == "Type" }
    }

    /// The write half: what `NSPopUpButton.menu?.performActionForItem` used to drive directly is
    /// now exercised one layer down, against `TaskDraftCache` itself — there is no control left to
    /// click. This proves the cache retains and clears a draft correctly; it can no longer prove
    /// that choosing "Plan" in a live picker reaches `retainDrafts`/`drafts.retain` the way
    /// `TaskInspectorView.onChange(of: task.id)` is written to call it. That real wiring — the
    /// `onChange` firing `retainDrafts` on a task switch — is covered instead by driving the Body
    /// `TextEditor` (still a real `NSTextView` offscreen) through a task switch: see
    /// `CommentComposerTests.testEditingTheBodyThenSwitchingTasksRetainsTheDraftThroughTheRealOnChangeWiring`.
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

/// A Vision-recognized line is either exactly a field's label (macOS 27, this machine) or the
/// label merged with its value on one line (macOS 26 CI: "Model Project default", "Type Code =").
/// Accept both without matching an unrelated label that happens to start with the same word.
func isLabelLine(_ text: String, label: String) -> Bool {
    text == label || text.hasPrefix(label + " ")
}

/// Whether any recognized line in a row shows `word` — as its own line, or as a whitespace-
/// separated token inside a merged label+value line. A substring check alone would let "Code"
/// match inside "Encode", so split on whitespace instead.
func rowHasWord(_ row: [String], _ word: String) -> Bool {
    row.contains { $0.split(separator: " ").map(String.init).contains(word) }
}

/// Pins the matcher against the macOS 26 grouping this machine cannot reproduce by rendering
/// (this Mac runs macOS 27 — see the headless UI verification note). Fixture strings are the
/// exact OCR lines PR #51's CI run reported: `TaskTypeRenderTests.swift:83: ... no Model row:
/// ["Parser checks", "Ready Code human", ..., "Model Project default", "Type Code =", "Revert", ...]`.
final class LabelLineMatchingTests: XCTestCase {
    private let macOS26TypeRow = ["Type Code ="]
    private let macOS27TypeRow = ["Code"]

    func testIsLabelLineAcceptsBothGroupings() {
        XCTAssertTrue(isLabelLine("Model", label: "Model"), "macOS 27's bare label line")
        XCTAssertTrue(isLabelLine("Model Project default", label: "Model"), "macOS 26's merged label+value line")
        XCTAssertFalse(isLabelLine("Type Code =", label: "Model"), "a different field's merged line must not match")
    }

    func testRowHasWordAcceptsBothGroupings() {
        XCTAssertTrue(rowHasWord(macOS26TypeRow, "Code"), "macOS 26's merged row: \(macOS26TypeRow)")
        XCTAssertTrue(rowHasWord(macOS27TypeRow, "Code"), "macOS 27's single-word row: \(macOS27TypeRow)")
    }

    /// The matcher must still fail the test when the picker shows the wrong type — reproducing
    /// the macOS 26 grouping for a task typed `.docs` instead of `.code`.
    func testRowHasWordFailsOnTheWrongTypeUnderTheMacOS26Grouping() {
        let wrongTypeRow = ["Type Docs ="]
        XCTAssertFalse(rowHasWord(wrongTypeRow, "Code"), "must not match Code in: \(wrongTypeRow)")
        XCTAssertTrue(rowHasWord(wrongTypeRow, "Docs"), "sanity: the row does show Docs: \(wrongTypeRow)")
    }
}
