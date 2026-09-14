import Foundation
import XCTest
@testable import AgentBoardRuntime

final class SupportPathsTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/tester")

    func testDefaultWorktreeBaseAvoidsApplicationSupportAndItsSpace() {
        let base = SupportPaths.worktreeBase(environment: [:], home: home)
        XCTAssertEqual(base.path, "/Users/tester/.agentboard/worktrees")
        XCTAssertFalse(base.path.contains(" "), base.path)

        let root = SupportPaths.worktreeRoot(projectId: "abc-123", environment: [:], home: home)
        XCTAssertEqual(root.path, "/Users/tester/.agentboard/worktrees/abc-123")
    }

    func testSupportDirOverrideRedirectsWorktreesAwayFromTheHomeDirectory() {
        let scratch = "/tmp/ab-scratch"
        let environment = [SupportPaths.supportDirEnvKey: scratch]

        XCTAssertEqual(SupportPaths.appSupportDir(environment: environment, home: home).path, scratch)
        XCTAssertEqual(
            SupportPaths.worktreeBase(environment: environment, home: home).path,
            "/tmp/ab-scratch/worktrees"
        )
        XCTAssertEqual(
            SupportPaths.worktreeRoot(projectId: "abc-123", environment: environment, home: home).path,
            "/tmp/ab-scratch/worktrees/abc-123"
        )
    }

    func testEmptyOverrideFallsBackToTheDefaults() {
        let environment = [SupportPaths.supportDirEnvKey: ""]
        XCTAssertEqual(
            SupportPaths.worktreeBase(environment: environment, home: home).path,
            "/Users/tester/.agentboard/worktrees"
        )
        XCTAssertEqual(
            SupportPaths.appSupportDir(environment: environment, home: home).path,
            "/Users/tester/Library/Application Support/AgentBoard"
        )
    }
}
