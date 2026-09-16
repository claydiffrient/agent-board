import Foundation

/// What an approved `push` or `pull_request` approval should do. Stored as JSON on the approval row
/// so the human's grant carries the same branch and text the orchestrator asked for, not whatever
/// the board looks like by the time they get to it.
public struct PublishRequest: Codable, Sendable, Equatable {
    public var branch: String
    public var base: String?
    public var title: String?
    public var body: String?
    public var remote: String

    public init(branch: String, base: String? = nil, title: String? = nil, body: String? = nil, remote: String = "origin") {
        self.branch = branch
        self.base = base
        self.title = title
        self.body = body
        self.remote = remote
    }

    public func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    public static func decode(_ json: String?) throws -> PublishRequest {
        guard let json, let data = json.data(using: .utf8) else {
            throw PublishPolicyError.missingPayload
        }
        return try JSONDecoder().decode(PublishRequest.self, from: data)
    }
}

public enum PublishPolicyError: Error, CustomStringConvertible, Equatable, Sendable {
    case empty
    case malformed(String)
    case outsideProject(branch: String, baseBranch: String)
    case missingPayload

    public var description: String {
        switch self {
        case .empty:
            return "No branch was given."
        case .malformed(let branch):
            return "\"\(branch)\" is not a usable branch name."
        case .outsideProject(let branch, let baseBranch):
            return "Agent Board will only push branches it owns. \"\(branch)\" is neither an "
                + "`agentboard/…` branch nor this project's base branch `\(baseBranch)`."
        case .missingPayload:
            return "This approval carries no branch to publish."
        }
    }
}

/// Which branches the orchestrator's `push_branch` and `open_pull_request` may aim at. Pure, so the
/// refusal is testable without a repository — and narrow, so the tools cannot be pointed at an
/// arbitrary ref on the remote.
public enum PublishPolicy {
    public static let ownedPrefix = "agentboard/"

    /// Characters git itself refuses in a ref, plus the ones a `git push` argument would read as
    /// something other than a branch (`:` splits a refspec, a leading `-` reads as an option).
    private static let forbidden: Set<Character> = [":", "?", "*", "[", "\\", "^", "~", " ", "\t", "\n"]

    @discardableResult
    public static func validate(branch raw: String, baseBranch: String) throws -> String {
        let branch = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else { throw PublishPolicyError.empty }
        guard isWellFormed(branch) else { throw PublishPolicyError.malformed(branch) }
        guard branch == baseBranch.trimmingCharacters(in: .whitespacesAndNewlines) || isOwned(branch) else {
            throw PublishPolicyError.outsideProject(branch: branch, baseBranch: baseBranch)
        }
        return branch
    }

    /// `agentboard/<something>` — the prefix alone is not a branch.
    public static func isOwned(_ branch: String) -> Bool {
        branch.hasPrefix(ownedPrefix) && branch.count > ownedPrefix.count
    }

    private static func isWellFormed(_ branch: String) -> Bool {
        guard !branch.hasPrefix("-"), !branch.hasPrefix("/"), !branch.hasSuffix("/"),
              !branch.hasSuffix("."), !branch.hasSuffix(".lock"), !branch.contains(".."),
              !branch.contains("//"), !branch.contains("@{"), branch != "@"
        else { return false }
        return !branch.contains(where: { forbidden.contains($0) || $0.asciiValue.map { $0 < 0x20 || $0 == 0x7F } == true })
    }
}
