import AgentBoardCore
import XCTest
@testable import AgentBoard

final class CommentComposerTests: XCTestCase {
    func testSubmitWritesAHumanCommentAndRefusesABlankDraft() throws {
        let db = try AppDatabase.inMemory()
        let project = try ProjectStore(db).register(
            name: "Demo", repoPath: "/tmp/demo-\(UUID().uuidString)", baseBranch: "main",
            worktreeRoot: "/tmp/demo-worktrees", memoryDir: nil
        )
        let task = try TaskStore(db).create(
            projectId: project.id, title: "t", body: nil, acceptance: nil, priority: nil,
            column: .backlog, origin: .human, epicId: nil
        )

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
}
