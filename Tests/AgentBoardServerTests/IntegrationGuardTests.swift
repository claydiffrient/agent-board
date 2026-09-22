import AgentBoardServer
import Foundation
import XCTest

final class IntegrationGuardTests: XCTestCase {
    private func violation(_ command: String, tool: String = "Bash") -> IntegrationGuard.Violation? {
        IntegrationGuard.violation(toolName: tool, command: command)
    }

    private func orchestrator(_ command: String, tool: String = "Bash") -> IntegrationGuard.Violation? {
        IntegrationGuard.violation(toolName: tool, command: command, scope: .orchestrator)
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

    func testAnAbsolutePathIsMatchedLikeTheBareSpelling() {
        XCTAssertEqual(violation("/usr/bin/git push"), .push)
        XCTAssertEqual(violation("/opt/homebrew/bin/git push"), .push)
        XCTAssertEqual(violation("./git push -u origin HEAD"), .push)
        XCTAssertEqual(violation("~/bin/git push"), .push)
        XCTAssertEqual(violation("cd /repo && /usr/bin/git -C /repo push origin main"), .push)
        XCTAssertEqual(violation("/usr/bin/gh pr create --draft"), .pullRequestCreate)
        XCTAssertEqual(violation("/opt/homebrew/bin/gh pr create"), .pullRequestCreate)
        XCTAssertEqual(violation("/opt/homebrew/bin/gh pr merge 42 --squash"), .pullRequestMerge)
    }

    /// The same rule reaches `invokesGit`, which is what `SharedCheckoutGuard` denies commits with.
    func testAnAbsolutePathIsSeenByTheSubcommandScanToo() {
        XCTAssertTrue(IntegrationGuard.invokesGit("commit", toolName: "Bash", command: "/usr/bin/git commit -m x"))
        XCTAssertTrue(IntegrationGuard.invokesGit("commit", toolName: "Bash", command: "git commit -m x"))
        XCTAssertTrue(IntegrationGuard.invokesGit("stash", toolName: "Bash", command: "/opt/homebrew/bin/git stash"))
        XCTAssertFalse(IntegrationGuard.invokesGit("commit", toolName: "Bash", command: "/usr/bin/mygit commit"))
    }

    func testATokenThatMerelyContainsGitOrGhIsNotMatched() {
        XCTAssertNil(violation("mygit push"))
        XCTAssertNil(violation("git-crypt push"))
        XCTAssertNil(violation("legit push"))
        XCTAssertNil(violation("/usr/bin/mygit push"))
        XCTAssertNil(violation("/usr/local/bin/git-crypt push"))
        XCTAssertNil(violation("gitk"))
        XCTAssertNil(violation("/usr/bin/ghq push"))
        XCTAssertNil(violation("ghost pr create"))
    }

    /// The scan is a heuristic and these get past it. Pinned so a later change that closes one is
    /// a visible edit here rather than a silent claim that the guard is sound.
    func testSpellingsTheScanIsKnownToMiss() {
        XCTAssertNil(violation("G=/usr/bin/git; $G push"))
        XCTAssertNil(violation("git $SUBCOMMAND"))
        XCTAssertNil(violation("/usr/bin/GIT push"))
        XCTAssertNil(violation("g''it push"))
        XCTAssertNil(violation("eval \"$(echo Z2l0IHB1c2g= | base64 -d)\""))
        XCTAssertNil(violation("./my-push-wrapper.sh"))
        // Over-matched in the other direction: the word is only ever mentioned, never run.
        XCTAssertEqual(violation("echo git push"), .push)
    }

    func testOnlyAppliesToBash() {
        XCTAssertNil(IntegrationGuard.violation(toolName: "Write", command: "git push"))
        XCTAssertNil(IntegrationGuard.violation(toolName: nil, command: "git push"))
        XCTAssertNil(IntegrationGuard.violation(toolName: "Bash", command: nil))
        XCTAssertNil(IntegrationGuard.violation(toolName: "Bash", command: ""))
    }

    func testOrchestratorMayPushAndOpenPullRequestsButNotMergeThem() {
        XCTAssertNil(orchestrator("git push"))
        XCTAssertNil(orchestrator("git push -u origin HEAD"))
        XCTAssertNil(orchestrator("cd /repo && git push origin main"))
        XCTAssertNil(orchestrator("gh pr create --draft"))
        XCTAssertEqual(orchestrator("gh pr merge 42 --squash"), .pullRequestMerge)
    }

    func testTheSameCommandsStayDeniedForAWorker() {
        XCTAssertEqual(violation("git push"), .push)
        XCTAssertEqual(violation("gh pr create --draft"), .pullRequestCreate)
        XCTAssertEqual(violation("gh pr merge 42 --squash"), .pullRequestMerge)
    }

    func testTheScanItselfIsScopeIndependent() {
        XCTAssertEqual(IntegrationGuard.match(toolName: "Bash", command: "git push"), .push)
        XCTAssertEqual(IntegrationGuard.match(toolName: "Bash", command: "gh pr create"), .pullRequestCreate)
        XCTAssertNil(IntegrationGuard.match(toolName: "Bash", command: "git status"))
    }

    func testDenyTextNeverClaimsWorkersWhenItReachesAnOrchestrator() {
        for violation in IntegrationGuard.Violation.allCases {
            XCTAssertTrue(violation.reason(for: .worker).contains("workers"), violation.rawValue)
            XCTAssertFalse(violation.reason(for: .orchestrator).contains("worker"), violation.reason(for: .orchestrator))
        }
    }

    func testTheOrchestratorDenyTextNamesTheToolToCallInstead() {
        XCTAssertTrue(IntegrationGuard.Violation.push.reason(for: .orchestrator).contains("push_branch"))
        XCTAssertTrue(
            IntegrationGuard.Violation.pullRequestCreate.reason(for: .orchestrator).contains("open_pull_request")
        )
        XCTAssertFalse(
            IntegrationGuard.Violation.pullRequestMerge.reason(for: .orchestrator).contains("open_pull_request")
        )
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
