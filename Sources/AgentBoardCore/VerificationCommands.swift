import Foundation

/// How a project builds and tests itself, as it reaches a prompt. Blank strings normalize to nil,
/// so a field cleared in the settings sheet behaves exactly like one that was never set.
public struct VerificationCommands: Sendable, Equatable {
    public var build: String?
    public var test: String?

    public init(build: String? = nil, test: String? = nil) {
        self.build = Self.normalized(build)
        self.test = Self.normalized(test)
    }

    static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    public var isEmpty: Bool { build == nil && test == nil }

    private static let workItOut = "work out how this project does it — read its build files, scripts and CI config"

    /// The integrator's verification instruction. Never degrades to silence when nothing is
    /// configured: a merge that compiles nothing is worse than one that names an unfamiliar command.
    public var integratorInstruction: String {
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

    /// Completes "…and <this>." in the integrator's report instruction.
    public var reportInstruction: String {
        if let build, let test {
            return "the final result of `\(build)` and `\(test)`"
        }
        return "the build and test commands you ran, named exactly, and how they came out"
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
        VerificationCommands(build: buildCommand, test: testCommand)
    }
}
