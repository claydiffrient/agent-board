import Foundation

/// Where in an outgoing publish a private term was found.
public enum PrivateTermSite: Sendable, Equatable, CustomStringConvertible {
    case file(String, commit: String)
    case commit(subject: String)
    case branchName(String)
    case pullRequestTitle
    case pullRequestBody

    public var description: String {
        switch self {
        case .file(let path, let commit): return "\(path) in commit \"\(commit)\""
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
    /// `PublishCommand.commitPatches`: each commit's subject line, then its patch.
    public var commitPatches: String

    public init(
        publishedBranch: String, title: String? = nil, body: String? = nil,
        commitMessages: String = "", commitPatches: String = ""
    ) {
        self.publishedBranch = publishedBranch
        self.title = title
        self.body = body
        self.commitMessages = commitMessages
        self.commitPatches = commitPatches
    }
}

/// SPEC §13.5: the publish guard. A term matches as a case-insensitive substring; blank terms are
/// dropped, since an empty one would match everything. Only added lines count, so a commit that
/// removes a term is not refused for it; NULs are dropped from them so UTF-16 text still matches.
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
        for file in changedFiles(inLog: outgoing.commitPatches) {
            let site = PrivateTermSite.file(file.path, commit: file.subject)
            candidates += [(file.path, site), (file.added, site)]
        }

        for candidate in candidates {
            if let term = terms.first(where: { candidate.text.range(of: $0, options: .caseInsensitive) != nil }) {
                return PrivateTermMatch(term: term, site: candidate.site)
            }
        }
        return nil
    }

    /// Each commit's files with their added lines joined. Expects `--src-prefix=a/ --dst-prefix=b/`
    /// and `--no-renames`, so a `diff --git` header names one path twice. `\r\n` is one Swift
    /// `Character`, so a CRLF file's lines split only when it is a separator too.
    static func changedFiles(inLog log: String) -> [(subject: String, path: String, added: String)] {
        var files: [(subject: String, path: String, added: String)] = []
        var subject = ""
        var inHunk = false
        for line in log.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            if line.hasPrefix(PublishCommand.commitMarker) {
                subject = String(line.dropFirst(PublishCommand.commitMarker.count))
                inHunk = false
            } else if line.hasPrefix("diff --git ") {
                files.append((subject, headerPath(line.dropFirst("diff --git ".count)), ""))
                inHunk = false
            } else if line.hasPrefix("@@") {
                inHunk = true
            } else if inHunk, line.hasPrefix("+"), !files.isEmpty {
                files[files.count - 1].added += line.dropFirst().filter { $0 != "\0" } + "\n"
            }
        }
        return files
    }

    /// `a/P b/P`, or `"a/Q" "b/Q"` when git C-quotes the path.
    static func headerPath(_ header: Substring) -> String {
        let bytes = Array(header.utf8)
        let second = bytes.suffix((bytes.count - 1) / 2)
        guard second.first == UInt8(ascii: "\""), second.count >= 4 else {
            return String(decoding: second.dropFirst(2), as: UTF8.self)
        }
        return unquoted(second.dropFirst(3).dropLast())
    }

    private static let escapes: [UInt8: UInt8] = [
        UInt8(ascii: "a"): 0x07, UInt8(ascii: "b"): 0x08, UInt8(ascii: "t"): 0x09, UInt8(ascii: "n"): 0x0A,
        UInt8(ascii: "v"): 0x0B, UInt8(ascii: "f"): 0x0C, UInt8(ascii: "r"): 0x0D,
    ]

    static func unquoted(_ quoted: ArraySlice<UInt8>) -> String {
        var bytes: [UInt8] = []
        var index = quoted.startIndex
        while index < quoted.endIndex {
            let byte = quoted[index]
            index += 1
            guard byte == UInt8(ascii: "\\"), index < quoted.endIndex else {
                bytes.append(byte)
                continue
            }
            let escape = quoted[index]
            index += 1
            if (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(escape) {
                var value = Int(escape - UInt8(ascii: "0"))
                for _ in 0..<2 where index < quoted.endIndex
                    && (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(quoted[index]) {
                    value = value * 8 + Int(quoted[index] - UInt8(ascii: "0"))
                    index += 1
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
            } else {
                bytes.append(escapes[escape] ?? escape)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
