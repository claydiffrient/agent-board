import Foundation

/// How a project builds and tests itself, as it reaches a prompt. Blank strings normalize to nil,
/// so a field cleared in the settings sheet behaves exactly like one that was never set.
public struct VerificationCommands: Sendable, Equatable {
    public var build: String?
    public var test: String?
    public var integration: IntegrationVerification

    public init(build: String? = nil, test: String? = nil, integration: IntegrationVerification = .buildAndTest) {
        self.build = Self.normalized(build)
        self.test = Self.normalized(test)
        self.integration = integration
    }

    static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    public var isEmpty: Bool { build == nil && test == nil }

    private static let workItOut = "work out how this project does it — read its build files, scripts and CI config"

    /// The integrator's verification instruction under `integration` (SPEC §5.2 step 3). Never
    /// degrades to silence when no command is configured: a merge that compiles nothing is worse
    /// than one that names an unfamiliar command.
    public func integratorInstruction(epicBranch: String, baseBranch: String, mergedBranches: [String]) -> String {
        switch integration {
        case .buildAndTest:
            return buildAndTestInstruction
        case .buildOnly:
            let build = build.map { "run `\($0)`" } ?? "build this project — \(Self.workItOut)"
            return "\(build). Do not run the tests: this project's CI runs them when the pull request opens. "
                + "Fix what breaks and build again until it is green. Name in your report exactly what you ran."
        case .ciVerifies:
            return ciVerifiesInstruction(epicBranch: epicBranch, baseBranch: baseBranch, mergedBranches: mergedBranches)
        }
    }

    private var buildAndTestInstruction: String {
        switch (build, test) {
        case let (build?, test?):
            return "run `\(build)` and then `\(test)`. Fix what breaks and run them again until both are green."
        case let (build?, nil):
            return "run `\(build)`, then run this project's tests — \(Self.workItOut). "
                + "Fix what breaks and run both again until they are green. Name in your report exactly what you ran."
        case let (nil, test?):
            return "build this project — \(Self.workItOut) — then run `\(test)`. "
                + "Fix what breaks and run both again until they are green. Name in your report exactly what you ran."
        case (nil, nil):
            return "build and test this project — \(Self.workItOut) — and run both. "
                + "Fix what breaks and run them again until they are green. Name in your report exactly what you ran."
        }
    }

    /// A conflict resolved by hand is new code no worker compiled, so it still gets a build.
    private func ciVerifiesInstruction(epicBranch: String, baseBranch: String, mergedBranches: [String]) -> String {
        let ancestry = mergedBranches.isEmpty
            ? "  - for each task branch you merged, `git merge-base --is-ancestor <branch> \(epicBranch)` exits 0"
            : mergedBranches.map { "  - `git merge-base --is-ancestor \($0) \(epicBranch)` exits 0" }.joined(separator: "\n")
        let fullBuild = build.map { " (the full build is `\($0)`)" } ?? ""
        return """
        do not build and do not run tests: this project's CI builds and tests the epic when its pull request opens. Check only that the merges are complete:
        \(ancestry)
          - `git diff \(baseBranch)...\(epicBranch) | grep -nE '^\\+(<<<<<<<|>>>>>>>)( |$)'` prints nothing, so no conflict marker was committed
          Fix anything either check finds. If you resolved a conflict by hand, run the narrowest build that compiles the files you resolved\(fullBuild), because nobody has compiled that resolution; still run no tests.
        """
    }

    /// The integrator's "keep it in the foreground" sentence, naming only what `integration` lets it run.
    public var foregroundInstruction: String {
        switch integration {
        case .buildAndTest:
            return "Run the build and tests in the foreground; if one is moved to the background, keep reading its output until it finishes."
        case .buildOnly:
            return "Run the build in the foreground; if it is moved to the background, keep reading its output until it finishes."
        case .ciVerifies:
            return "If you build a hand-resolved conflict, run that build in the foreground; if it is moved to the background, "
                + "keep reading its output until it finishes."
        }
    }

    /// Completes "…and <this>." in the integrator's report instruction.
    public var reportInstruction: String {
        switch integration {
        case .buildAndTest:
            if let build, let test {
                return "the final result of `\(build)` and `\(test)`"
            }
            return "the build and test commands you ran, named exactly, and how they came out"
        case .buildOnly:
            let build = build.map { "the final result of `\($0)`" } ?? "the build command you ran, named exactly, and how it came out"
            return "\(build), and that the tests were left to CI"
        case .ciVerifies:
            return "the outcome of the ancestry and conflict-marker checks, any build you ran for a hand-resolved conflict, "
                + "and that the build and tests were left to CI"
        }
    }

    /// The worker's verification section, or nil when the project configured neither command —
    /// workers already infer verification from the repo, and a docs-only task should not be handed
    /// a build directive it did not ask for.
    public var workerSection: String? {
        let claim: String
        switch (build, test) {
        case let (build?, test?):
            claim = "This project builds with `\(build)` and tests with `\(test)`."
        case let (build?, nil):
            claim = "This project builds with `\(build)`. Run its tests too — \(Self.workItOut)."
        case let (nil, test?):
            claim = "This project tests with `\(test)`. Build it too — \(Self.workItOut)."
        case (nil, nil):
            return nil
        }
        return """
        ## Verification
        \(claim)
        Run them before you report, and name in your report exactly what you ran and how it came out.
        """
    }
}

extension ProjectSettings {
    public var verification: VerificationCommands {
        VerificationCommands(build: buildCommand, test: testCommand, integration: integrationVerification)
    }
}
