import Foundation
import XCTest
@testable import AgentBoardCore

final class WorktreeRootRuleTests: XCTestCase {
    func testASpaceFreePathPasses() {
        XCTAssertNoThrow(try WorktreeRootRule.validate("/Users/me/.agentboard/worktrees/abc"))
        XCTAssertTrue(WorktreeRootRule.isValid("/Users/me/.agentboard/worktrees/abc"))
    }

    func testASpacedPathIsRefusedAndSaysTheSpaceIsWhy() {
        let path = "/Users/me/Library/Application Support/AgentBoard/worktrees/abc"
        XCTAssertFalse(WorktreeRootRule.isValid(path))
        XCTAssertThrowsError(try WorktreeRootRule.validate(path)) { error in
            XCTAssertEqual(error as? WorktreeRootError, .containsSpace(path))
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("space"), message)
            XCTAssertTrue(message.contains(path), message)
        }
    }

    func testAnEmptyPathIsRefused() {
        XCTAssertThrowsError(try WorktreeRootRule.validate("   ")) { error in
            XCTAssertEqual(error as? WorktreeRootError, .empty)
        }
    }

    func testRegisteringAProjectWithASpacedWorktreeRootIsRefused() throws {
        let db = try AppDatabase.inMemory()
        let projects = ProjectStore(db)
        XCTAssertThrowsError(
            try projects.register(
                name: "spaced", repoPath: "/tmp/spaced", baseBranch: "main",
                worktreeRoot: "/Users/me/Library/Application Support/AgentBoard/worktrees/abc",
                memoryDir: nil
            )
        ) { error in
            XCTAssertEqual(
                error as? WorktreeRootError,
                .containsSpace("/Users/me/Library/Application Support/AgentBoard/worktrees/abc")
            )
        }
        XCTAssertEqual(try projects.list().count, 0)
    }
}
