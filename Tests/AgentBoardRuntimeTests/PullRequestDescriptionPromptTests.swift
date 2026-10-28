import AgentBoardRuntime
import XCTest
@testable import AgentBoardCore

final class PullRequestDescriptionPromptTests: XCTestCase {
    /// SPEC §13.1: the follow-up check can't run `gh`, so a description edit is graded from what the poll stored.
    func testAPolledDescriptionReachesTheFollowupCheckPromptFenced() throws {
        let json = """
        {"data": {"viewer": {"login": "me"}, "repository": {"pr7": {
          "number": 7, "url": "https://github.com/example-org/app/pull/7", "title": "Add a widget",
          "body": "## Testing\\nRan the widget suite.<!-- template hint -->",
          "isDraft": false, "headRefName": "feature/widget", "headRefOid": "abc123", "baseRefName": "main"
        }}}}
        """
        let snapshot = try XCTUnwrap(
            PullRequestWatchReader.parseSnapshots(json, owner: "example-org", name: "app")?.first
        )
        let db = try AppDatabase.inMemory()
        let project = try ProjectStore(db).register(
            name: "App", repoPath: "/repo", baseBranch: "main", worktreeRoot: "/w", memoryDir: nil
        )
        let stored = try XCTUnwrap(PRWatchStore(db).get(PRWatchStore(db).upsert(projectId: project.id, snapshot: snapshot).id))
        let round = PRRound(
            id: 1, watchId: stored.id, number: 1, baseHeadOid: "abc123", pushedHeadOid: nil, outcome: nil,
            startedAt: 0, endedAt: nil
        )

        let prompt = FollowupCheckPrompt.compose(
            watch: stored, round: round, headOid: "def456", workingDirectory: "/w/check", fenceId: "f1"
        )

        let fenced = """
        <<<GITHUB PULL REQUEST DESCRIPTION id=f1>>>
        ## Testing
        Ran the widget suite.
        <<<END GITHUB PULL REQUEST DESCRIPTION id=f1>>>
        """
        XCTAssertTrue(prompt.contains(fenced), prompt)
    }
}
