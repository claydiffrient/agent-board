import AgentBoardCore
import AppKit
import Observation
import SwiftUI
import XCTest
@testable import AgentBoard

@MainActor
final class CommentComposerTests: XCTestCase {
    private var db: AppDatabase!
    private var project: Project!

    override func setUp() async throws {
        db = try AppDatabase.inMemory()
        project = try ProjectStore(db).register(
            name: "Demo", repoPath: "/tmp/demo-\(UUID().uuidString)", baseBranch: "main",
            worktreeRoot: "/tmp/demo-worktrees", memoryDir: nil
        )
    }

    func testSubmitWritesAHumanCommentAndRefusesABlankDraft() throws {
        let task = try makeTask("t")

        XCTAssertFalse(CommentComposer.canSubmit(" \n\t"))
        XCTAssertNil(try CommentComposer.submit(" \n\t", to: task, db: db))
        XCTAssertNil(try CommentComposer.submit("", to: task, db: db))
        XCTAssertEqual(try CommentStore(db).list(taskId: task.id), [])

        XCTAssertTrue(CommentComposer.canSubmit(" Check the null case.\n"))
        let written = try XCTUnwrap(try CommentComposer.submit(" Check the null case.\n", to: task, db: db))

        let thread = try CommentStore(db).list(taskId: task.id)
        XCTAssertEqual(thread, [written])
        XCTAssertEqual(thread.first?.authorKind, .human)
        XCTAssertEqual(thread.first?.authorName, TaskComment.humanAuthorName)
        XCTAssertNil(thread.first?.authorSessionId)
        XCTAssertEqual(thread.first?.body, "Check the null case.")
        XCTAssertEqual(try CommentStore(db).counts(projectId: project.id), [task.id: 1])
    }

    func testADraftTypedForOneTaskIsNeverSubmittedToAnother() throws {
        let a = try makeTask("A")
        let b = try makeTask("B")
        let drafts = TaskDraftCache()
        let env = renderEnvironment(db: db)

        drafts.setComment("stop, the migration is wrong", for: a.id)
        XCTAssertNil(try CommentComposer.submit(from: drafts, to: b, env: env))
        XCTAssertEqual(try CommentStore(db).list(taskId: b.id), [])
        XCTAssertEqual(drafts.comment(for: a.id), "stop, the migration is wrong")

        XCTAssertNotNil(try CommentComposer.submit(from: drafts, to: a, env: env))
        XCTAssertEqual(try CommentStore(db).list(taskId: a.id).map(\.body), ["stop, the migration is wrong"])
        XCTAssertEqual(drafts.comment(for: a.id), "")
    }

    /// The board keeps one inspector mounted and swaps its task, as `TaskBoardView` does on a new selection.
    func testTheComposerShowsEachSelectedTasksOwnDraft() throws {
        let a = try makeTask("A")
        let b = try makeTask("B")
        let selection = Selection(task: a)
        let mount = OffscreenMount(
            SelectedInspector(selection: selection, drafts: TaskDraftCache())
                .environment(renderEnvironment(db: db)),
            size: CGSize(width: 420, height: 1400)
        )
        defer { mount.close() }

        let typed = "stop, the migration is wrong"
        let editors = settle(mount.host) { $0.count == 3 }
        XCTAssertEqual(editors.map(\.string), ["A body", "A acceptance", ""])
        let composer = try XCTUnwrap(editors.last)
        composer.insertText(typed, replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(settle(mount.host) { $0.last?.string == typed }.last?.string, typed)

        selection.task = b
        let onB = settle(mount.host) { $0.first?.string == "B body" && $0.last?.string != typed }
        XCTAssertEqual(onB.map(\.string), ["B body", "B acceptance", ""], "task A's draft is showing in task B's composer")

        selection.task = a
        let backOnA = settle(mount.host) { $0.first?.string == "A body" && $0.last?.string == typed }
        XCTAssertEqual(backOnA.last?.string, typed, "task A's draft was lost")
        XCTAssertEqual(try CommentStore(db).list(taskId: b.id), [])
    }

    private func makeTask(_ title: String) throws -> BoardTask {
        try TaskStore(db).create(
            projectId: project.id, title: title, body: "\(title) body", acceptance: "\(title) acceptance",
            priority: nil, column: .backlog, origin: .human, epicId: nil
        )
    }

    /// Pumps until `done` holds for the mounted editors, top to bottom, then a little longer.
    private func settle(_ host: NSView, until done: ([NSTextView]) -> Bool) -> [NSTextView] {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        } while !done(textViews(in: host)) && Date() < deadline
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        return textViews(in: host)
    }

    private func textViews(in view: NSView) -> [NSTextView] {
        var found: [NSTextView] = []
        func walk(_ view: NSView) {
            if let text = view as? NSTextView { found.append(text) }
            view.subviews.forEach(walk)
        }
        walk(view)
        return found.sorted { $0.convert(NSPoint.zero, to: nil).y > $1.convert(NSPoint.zero, to: nil).y }
    }
}

@Observable
private final class Selection {
    var task: BoardTask
    init(task: BoardTask) { self.task = task }
}

private struct SelectedInspector: View {
    let selection: Selection
    let drafts: TaskDraftCache

    var body: some View {
        TaskInspectorView(task: selection.task, allTasks: [], sessions: [], drafts: drafts, onClose: {})
    }
}
