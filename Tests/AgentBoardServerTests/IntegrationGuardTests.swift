import AgentBoardServer
import Foundation
import XCTest

final class IntegrationGuardTests: XCTestCase {
    private func violation(_ command: String, tool: String = "Bash") -> IntegrationGuard.Violation? {
        IntegrationGuard.violation(toolName: tool, command: command)
    }

    func testDeniesTheThreeDisallowedShapes() {
        XCTAssertEqual(violation("git push"), .push)
        XCTAssertEqual(violation("gh pr create"), .pullRequestCreate)
        XCTAssertEqual(violation("gh pr merge 42"), .pullRequestMerge)
    }

    func testDeniesFlaggedAndWrappedInvocations() {
        XCTAssertEqual(violation("git push -u origin HEAD"), .push)
        XCTAssertEqual(violation("git push --force-with-lease"), .push)
        XCTAssertEqual(violation("git -C /repo push origin main"), .push)
        XCTAssertEqual(violation("GIT_SSH_COMMAND='ssh -i k' git push"), .push)
        XCTAssertEqual(violation("cd /repo && git push origin main"), .push)
        XCTAssertEqual(violation("git add -A; git commit -m wip; git push"), .push)
        XCTAssertEqual(violation("sh -c \"gh pr create --draft\""), .pullRequestCreate)
        XCTAssertEqual(violation("gh pr merge --admin --squash"), .pullRequestMerge)
        XCTAssertEqual(violation("echo hi | xargs -I{} git push"), .push)
    }

    func testAllowsUnrelatedCommands() {
        XCTAssertNil(violation("git status"))
        XCTAssertNil(violation("git commit -m \"Add hello.txt\""))
        XCTAssertNil(violation("git log --grep=push"))
        XCTAssertNil(violation("gh pr view 42"))
        XCTAssertNil(violation("gh pr list"))
        XCTAssertNil(violation("swift test"))
        XCTAssertNil(violation("echo push"))
    }

    func testOnlyAppliesToBash() {
        XCTAssertNil(IntegrationGuard.violation(toolName: "Write", command: "git push"))
        XCTAssertNil(IntegrationGuard.violation(toolName: nil, command: "git push"))
        XCTAssertNil(IntegrationGuard.violation(toolName: "Bash", command: nil))
        XCTAssertNil(IntegrationGuard.violation(toolName: "Bash", command: ""))
    }

    func testDenyBodyCarriesBothDecisionShapes() throws {
        let body = HookDecision.deny(IntegrationGuard.Violation.push.reason).responseBody(hookEventName: "PreToolUse")
        let specific = try XCTUnwrap(body["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(specific["hookEventName"] as? String, "PreToolUse")
        XCTAssertEqual(specific["permissionDecision"] as? String, "deny")
        XCTAssertEqual(specific["permissionDecisionReason"] as? String, IntegrationGuard.Violation.push.reason)
        XCTAssertEqual(body["decision"] as? String, "block")
        XCTAssertEqual(body["reason"] as? String, IntegrationGuard.Violation.push.reason)
    }
}
