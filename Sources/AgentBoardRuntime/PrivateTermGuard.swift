import Foundation

/// Where in an outgoing publish a private term was found.
public enum PrivateTermSite: Sendable, Equatable, CustomStringConvertible {
    case file(String)
    case commit(subject: String)
    case branchName(String)
    case pullRequestTitle
    case pullRequestBody

    public var description: String {
        switch self {
        case .file(let path): return "the diff of \(path)"
        case .commit(let subject): return "the message of commit \"\(subject)\""
        case .branchName(let name): return "the branch name \(name)"
        case .pullRequestTitle: return "the pull request title"
        case .pullRequestBody: return "the pull request body"
        }
    }
}

public struct PrivateTermMatch: Sendable, Equatable {
    public var term: String
    public var site: PrivateTermSite

    public init(term: String, site: PrivateTermSite) {
        self.term = term
        self.site = site
    }
}

/// What a publish would send, gathered before anything leaves the machine.
public struct OutgoingPublish: Sendable, Equatable {
    public var publishedBranch: String
    public var title: String?
    public var body: String?
    /// `git log -z --format=%B`: NUL-separated messages.
    public var commitMessages: String
    public var changedPaths: [String]
    public var diff: String

    public init(
        publishedBranch: String, title: String? = nil, body: String? = nil,
        commitMessages: String = "", changedPaths: [String] = [], diff: String = ""
    ) {
        self.publishedBranch = publishedBranch
        self.title = title
        self.body = body
        self.commitMessages = commitMessages
        self.changedPaths = changedPaths
        self.diff = diff
    }
}

/// SPEC §13.5: the publish guard. A term matches as a case-insensitive substring; blank terms are
/// dropped, since an empty one would match everything. Only added diff lines count, so a commit
/// that removes a term is not refused for it.
public enum PrivateTermGuard {
    public static func firstMatch(terms: [String], in outgoing: OutgoingPublish) -> PrivateTermMatch? {
        let terms = terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }

        var candidates: [(text: String, site: PrivateTermSite)] = [
            (outgoing.publishedBranch, .branchName(outgoing.publishedBranch)),
        ]
        if let title = outgoing.title { candidates.append((title, .pullRequestTitle)) }
        if let body = outgoing.body { candidates.append((body, .pullRequestBody)) }
        for message in outgoing.commitMessages.split(separator: "\0").map(String.init) {
            let subject = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            candidates.append((message, .commit(subject: subject)))
        }
        candidates += outgoing.changedPaths.map { ($0, .file($0)) }
        candidates += addedLines(inDiff: outgoing.diff).map { ($0.text, .file($0.path)) }

        for candidate in candidates {
            if let term = terms.first(where: { candidate.text.range(of: $0, options: .caseInsensitive) != nil }) {
                return PrivateTermMatch(term: term, site: candidate.site)
            }
        }
        return nil
    }

    /// Each file's added lines, joined. Expects `--src-prefix=a/ --dst-prefix=b/`.
    static func addedLines(inDiff diff: String) -> [(path: String, text: String)] {
        var files: [(path: String, text: String)] = []
        var inHunk = false
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                files.append((path: "", text: ""))
                inHunk = false
            } else if line.hasPrefix("@@") {
                inHunk = true
            } else if !inHunk, line.hasPrefix("+++ b/"), !files.isEmpty {
                files[files.count - 1].path = String(line.dropFirst("+++ b/".count))
            } else if inHunk, line.hasPrefix("+"), !files.isEmpty {
                files[files.count - 1].text += line.dropFirst() + "\n"
            }
        }
        return files.filter { !$0.text.isEmpty }
    }
}
