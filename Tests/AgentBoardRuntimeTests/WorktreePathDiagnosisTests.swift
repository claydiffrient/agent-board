import XCTest
@testable import AgentBoardRuntime

/// The fixtures are verbatim captures of `git worktree add` failing because the repository's
/// `post-checkout` hook ran its Bazel setup in the new worktree. `Fixture.worktreePath` is the path
/// each capture was taken at.
private enum Fixture {
    static let spacedWorktree = "/Users/claydiffrient/Library/Application Support/AgentBoard/worktrees"
        + "/f7c95040-65a6-41e2-84a6-d5aed1d809f6/1064a204-6c7c-42ee-82f8-b1764d2c1359"
        + "/.capture/worktrees/36bf1b10-2aca-4dfd-89df-57a7ecd3a570"

    static let missingTargetWorktree = "/Users/claydiffrient/Library/Application Support/AgentBoard/worktrees"
        + "/f7c95040-65a6-41e2-84a6-d5aed1d809f6/1064a204-6c7c-42ee-82f8-b1764d2c1359"
        + "/.capture/worktrees/9f2c1d40-1111-4bcd-9a7e-52ab0f8c7311"

    static let missingToolWorktree = "/Users/claydiffrient/Library/Application Support/AgentBoard/worktrees"
        + "/f7c95040-65a6-41e2-84a6-d5aed1d809f6/1064a204-6c7c-42ee-82f8-b1764d2c1359"
        + "/.capture/worktrees/c41e77b2-2222-4a19-8f10-6d0e9a1b4455"

    static func load(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"),
            "missing fixture \(name).txt"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }
}

final class WorktreePathDiagnosisTests: XCTestCase {
    func testNamesTheSplitPrefixInTheCapturedBazelFailure() throws {
        let output = try Fixture.load("bazel-setup-space-failure")

        let evidence = try XCTUnwrap(
            WorktreePathDiagnosis.splitPath(worktreePath: Fixture.spacedWorktree, output: output)
        )

        XCTAssertEqual(evidence.prefix, "/Users/claydiffrient/Library/Application")
        XCTAssertEqual(evidence.hazard, "a space")
        XCTAssertEqual(evidence.line, "/bin/sh: /Users/claydiffrient/Library/Application: No such file or directory")
    }

    func testExplanationLeadsAndTheFullOutputSurvivesBelowIt() throws {
        let output = try Fixture.load("bazel-setup-space-failure")

        let explained = WorktreePathDiagnosis.explain(output, worktreePath: Fixture.spacedWorktree)

        let headline = try XCTUnwrap(explained.split(separator: "\n", omittingEmptySubsequences: false).first)
        XCTAssertTrue(headline.contains("a space"), headline.description)
        XCTAssertTrue(headline.contains("/Users/claydiffrient/Library/Application"), headline.description)
        XCTAssertTrue(explained.hasSuffix(output), "the original output must survive unchanged below the headline")
        XCTAssertEqual(
            explained.split(separator: "\n").filter { $0.contains("INFO: Elapsed time") }.count,
            3,
            "every line of the captured Bazel output should still be there"
        )
    }

    func testABazelFailureWithNoMissingPathIsPassedThroughUnchanged() throws {
        let output = try Fixture.load("bazel-setup-missing-target-failure")

        XCTAssertNil(WorktreePathDiagnosis.splitPath(worktreePath: Fixture.missingTargetWorktree, output: output))
        XCTAssertEqual(WorktreePathDiagnosis.explain(output, worktreePath: Fixture.missingTargetWorktree), output)
    }

    /// The capture reports `No such file or directory` for a tool the repository's setup expected,
    /// not for the worktree path — guessing on it would bury the real error.
    func testAnUnrelatedMissingFileIsPassedThroughUnchanged() throws {
        let output = try Fixture.load("bazel-setup-missing-tool-failure")
        XCTAssertTrue(output.contains("No such file or directory"), "fixture no longer exercises the trap")

        XCTAssertNil(WorktreePathDiagnosis.splitPath(worktreePath: Fixture.missingToolWorktree, output: output))
        XCTAssertEqual(WorktreePathDiagnosis.explain(output, worktreePath: Fixture.missingToolWorktree), output)
    }

    func testAMissingFileNamingTheWholeWorktreePathIsNotASplit() {
        let path = "/Users/clay/Library/Application Support/AgentBoard/worktrees/p/t"
        let output = "cat: \(path)/setup.log: No such file or directory"

        XCTAssertNil(WorktreePathDiagnosis.splitPath(worktreePath: path, output: output))
    }

    func testASpaceFreeWorktreePathNeverMatches() throws {
        let output = try Fixture.load("bazel-setup-space-failure")
        let path = "/Users/claydiffrient/.agentboard/worktrees/p/36bf1b10-2aca-4dfd-89df-57a7ecd3a570"

        XCTAssertNil(WorktreePathDiagnosis.splitPath(worktreePath: path, output: output))
    }

    func testPreflightNamesThePathAndTheReason() throws {
        let warning = try XCTUnwrap(WorktreePathDiagnosis.preflight(worktreePath: Fixture.spacedWorktree))

        XCTAssertEqual(warning.path, Fixture.spacedWorktree)
        XCTAssertEqual(warning.found, ["a space"])
        XCTAssertTrue(warning.message.contains(Fixture.spacedWorktree), warning.message)
        XCTAssertTrue(warning.message.contains("a space"), warning.message)
        XCTAssertTrue(warning.message.contains("without quoting"), warning.message)
    }

    func testPreflightPassesASpaceFreePath() {
        XCTAssertNil(
            WorktreePathDiagnosis.preflight(
                worktreePath: "/Users/claydiffrient/.agentboard/worktrees/p/36bf1b10-2aca-4dfd-89df-57a7ecd3a570"
            )
        )
    }

    func testPreflightReportsEveryShellSignificantCharacter() throws {
        let warning = try XCTUnwrap(
            WorktreePathDiagnosis.preflight(worktreePath: "/Users/clay/Agent Board/work$trees/t")
        )

        XCTAssertEqual(warning.found, ["a space", "a dollar sign"])
        XCTAssertTrue(warning.message.contains("a space and a dollar sign"), warning.message)
    }
}
