import AgentBoardServer
import XCTest

/// The text half of the shared-checkout guard: what each command is judged to be, before anything
/// looks at who is running it. The "is this a shared worker" half is in the bridge tests.
final class SharedCheckoutGuardTests: XCTestCase {
    private func verdict(_ command: String) -> SharedCheckoutGuard.Verdict {
        SharedCheckoutGuard.inspect(toolName: "Bash", command: command)
    }

    private func denied(_ command: String) -> SharedCheckoutGuard.Violation? {
        if case .deny(let violation) = verdict(command) { return violation }
        return nil
    }

    func testEveryDeniedFormIsRecognisedAsItsOwnViolation() {
        let cases: [(String, SharedCheckoutGuard.Violation)] = [
            ("git commit -m \"x\"", .commit),
            ("git stash", .stash),
            ("git stash push -u", .stash),
            ("git stash save wip", .stash),
            ("git stash pop", .stash),
            ("git checkout .", .checkout),
            ("git checkout -- Sources/A.swift", .checkout),
            ("git checkout main", .checkout),
            ("git checkout -b feature", .checkout),
            ("git switch main", .switchBranch),
            ("git switch -c feature", .switchBranch),
            ("git reset --hard", .reset),
            ("git reset --hard HEAD~1", .reset),
            ("git reset", .reset),
            ("git reset --merge", .reset),
            ("git reset --keep origin/main", .reset),
            ("git clean -fd", .clean),
            ("git clean -fdx", .clean),
            ("git clean -n", .clean),
            ("git restore .", .restore),
            ("git restore Sources", .restore),
            ("git restore --staged .", .restore),
            ("git rm -r Sources", .remove),
            ("git sparse-checkout set Sources", .sparseCheckout),
            ("git merge agentboard/other", .merge),
            ("git rebase main", .rebase),
            ("git pull", .pull),
            ("git cherry-pick abc1234", .cherryPick),
            ("git revert HEAD", .revert),
            ("git am patch.mbox", .applyMailbox),
            ("git bisect start", .bisect),
        ]
        for (command, expected) in cases {
            XCTAssertEqual(denied(command), expected, command)
        }
    }

    func testTheTokenizerVariantsAreCaughtTheSameWay() {
        XCTAssertEqual(denied("cd Sources && git stash"), .stash)
        XCTAssertEqual(denied("git -C /repos/demo reset --hard"), .reset)
        XCTAssertEqual(denied("git -c core.hooksPath=/dev/null checkout ."), .checkout)
        XCTAssertEqual(denied("git status; git clean -fd"), .clean)
        XCTAssertEqual(denied("echo hi | xargs -I{} git switch main"), .switchBranch)
        XCTAssertEqual(denied("GIT_AUTHOR_NAME=x git stash push"), .stash)
        XCTAssertEqual(denied("bash -c \"git reset --hard\""), .reset)
        XCTAssertEqual(denied("/usr/bin/git stash"), .stash)
        XCTAssertEqual(denied("git --git-dir=.git --work-tree=. clean -fd"), .clean)
    }

    func testTheFirstDeniedFormInAChainDecidesTheViolation() {
        XCTAssertEqual(denied("git stash && git checkout main"), .stash)
        XCTAssertEqual(denied("git log --oneline && git clean -fd"), .clean)
    }

    func testEveryDenialNamesWhatToDoInstead() {
        for violation in SharedCheckoutGuard.Violation.allCases {
            let reason = violation.reason
            XCTAssertTrue(
                reason.contains("commit_my_work")
                    || reason.contains("git restore -- <path>")
                    || reason.contains("git status --porcelain")
                    || reason.contains("git ls-files"),
                "`git \(violation.gitCommand)` is refused without naming an alternative: \(reason)"
            )
            XCTAssertTrue(reason.contains(violation.gitCommand), reason)
        }
    }

    func testTheRestoreDenialNamesTheAllowedFormAndTheOutOfScopePathsItRefused() {
        XCTAssertTrue(
            SharedCheckoutGuard.Violation.restore.reason.contains("git restore -- <path>"),
            SharedCheckoutGuard.Violation.restore.reason
        )
        let reason = SharedCheckoutGuard.restoreOutOfScopeReason(["Sources/Other.swift"])
        XCTAssertTrue(reason.contains("Sources/Other.swift"), reason)
        XCTAssertTrue(reason.contains("report_blocked"), reason)
    }

    func testScopedRestoreCarriesItsPathspecForTheLockCheck() {
        XCTAssertEqual(verdict("git restore -- Sources/A.swift"), .restoreScoped(paths: ["Sources/A.swift"]))
        XCTAssertEqual(
            verdict("git restore --staged --worktree -- Sources/A.swift Sources/B.swift"),
            .restoreScoped(paths: ["Sources/A.swift", "Sources/B.swift"])
        )
    }

    func testRestoreIsDeniedOutrightWheneverThePathsCannotBeTrusted() {
        // No `--`: a bare word may be a pathspec or a tree-ish depending on flags.
        XCTAssertEqual(denied("git restore Sources/A.swift"), .restore)
        // Relocated: the paths are not relative to the session's directory.
        XCTAssertEqual(denied("git -C /elsewhere restore -- Sources/A.swift"), .restore)
        // Shell in the command: a `cd` or a substitution the tokenizer has already discarded.
        XCTAssertEqual(denied("cd Sources && git restore -- A.swift"), .restore)
        XCTAssertEqual(denied("git restore -- $(ls)"), .restore)
        XCTAssertEqual(denied("git restore -- \"my file.swift\""), .restore)
        // Reading the pathspec from a file puts it out of the guard's sight.
        XCTAssertEqual(denied("git restore --pathspec-from-file=list.txt"), .restore)
        // An empty pathspec.
        XCTAssertEqual(denied("git restore --"), .restore)
    }

    func testReadingTheTreeAndEverythingUnrelatedIsAllowed() {
        for command in [
            "git status --porcelain",
            "git diff -- Sources/A.swift",
            "git log --oneline -20",
            "git show HEAD",
            "git ls-files Sources",
            "git grep TODO",
            "git add Sources/A.swift",
            "git branch --show-current",
            "git worktree list",
            "swift build",
            "rm Sources/Mine.swift",
            "restore the file",
        ] {
            XCTAssertEqual(verdict(command), .allow, command)
        }
    }

    /// SPEC §8: this is text matching over a tokenized command, not a shell AST. It over-matches a
    /// command that only mentions git, and it misses anything that hides the words. Pinned so the
    /// limit is a documented property rather than a surprise.
    func testTheMatchIsOverTextAndBothItsEdgesArePinned() {
        XCTAssertEqual(denied("echo git stash is the thing I must not run"), .stash)
        XCTAssertEqual(verdict("echo Z2l0IHN0YXNo | base64 -d | sh"), .allow)
        XCTAssertEqual(verdict("./scripts/wipe.sh"), .allow)
        XCTAssertEqual(verdict("alias g=git; g stash"), .allow)
    }

    func testANonBashToolIsNeverJudged() {
        XCTAssertEqual(SharedCheckoutGuard.inspect(toolName: "Edit", command: "git stash"), .allow)
        XCTAssertEqual(SharedCheckoutGuard.inspect(toolName: nil, command: "git stash"), .allow)
        XCTAssertEqual(SharedCheckoutGuard.inspect(toolName: "Bash", command: nil), .allow)
    }

    func testDeniesCommitStillAnswersForTheCommitCaseAlone() {
        XCTAssertTrue(SharedCheckoutGuard.deniesCommit(toolName: "Bash", command: "git commit -am x"))
        XCTAssertFalse(SharedCheckoutGuard.deniesCommit(toolName: "Bash", command: "git stash"))
        XCTAssertEqual(SharedCheckoutGuard.commitReason, SharedCheckoutGuard.Violation.commit.reason)
    }
}
