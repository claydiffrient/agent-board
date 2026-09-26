import AgentBoardCore
import AgentBoardRuntime
import XCTest

/// SPEC §8.2: the deny rule only stops editing tools and a few Bash file commands. Everything else
/// that can write inside a registered repo — `git commit` included — is left to instruction alone,
/// so both the system prompt and the seeded `CLAUDE.md` must name it explicitly.
final class CoordinatorPromptTests: XCTestCase {
    func testBothTextsNameGitCommitAsForbiddenInsideRegisteredRepos() {
        let prompt = CoordinatorPrompt.systemPrompt(readOnlyRepos: ["/repo"])
        XCTAssertTrue(prompt.contains("git commit"), prompt)
        XCTAssertTrue(CoordinatorHome.starterClaudeMd.contains("git commit"), CoordinatorHome.starterClaudeMd)
    }
}
