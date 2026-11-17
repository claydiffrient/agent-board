import AgentBoardCore
import XCTest

final class ProtectedPathsTests: XCTestCase {
    func testMatchesReviewRulesCIAndProjectGlobsButNotLookalikes() {
        let paths = [
            "CLAUDE.md",
            "Sources/Feature/CLAUDE.md",
            "pkg/CLAUDE.local.md",
            ".claude/skills/x/SKILL.md",
            "tools/.claude/settings.json",
            ".github/workflows/ci.yml",
            ".mcp.json",
            "scripts/hooks/pre-commit",
            "docs/claude.md",
            "docs/CLAUDE.md.bak",
            ".claude",
            ".github/dependabot.yml",
            "sub/.mcp.json",
            "src/.claudex/file",
            "scripts/build.sh",
        ]

        let hits = ProtectedPaths.matching(paths, extraGlobs: ["scripts/hooks/**"])

        XCTAssertEqual(hits, [
            "CLAUDE.md",
            "Sources/Feature/CLAUDE.md",
            "pkg/CLAUDE.local.md",
            ".claude/skills/x/SKILL.md",
            "tools/.claude/settings.json",
            ".github/workflows/ci.yml",
            ".mcp.json",
            "scripts/hooks/pre-commit",
        ])
    }
}
