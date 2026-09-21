import Foundation

/// SPEC §6.1. A branch name derived from a human title rather than from an id. Deterministic: the same title
/// always produces the same slug, because a second push that landed on a new name would leave the
/// pull request pointing at a stale ref.
public enum BranchSlug {
    /// 48 characters of slug leaves room for a namespace and a `-<short id>` collision suffix inside
    /// the ~60 characters GitHub shows before it truncates a head branch in a pull request header.
    public static let maxLength = 48

    /// Lowercase ASCII words joined by single hyphens, or nil when the title contributes no ASCII
    /// letters or digits at all — a wholly non-Latin or emoji-only title has no slug, and the caller
    /// falls back to the short id.
    ///
    /// Only canonical decomposition is applied, never transliteration: `é` becomes `e` because NFD
    /// separates the accent, but `日` is dropped rather than romanised, which would make the slug
    /// depend on the host's ICU version.
    public static func make(from title: String) -> String? {
        let folded = title.decomposedStringWithCanonicalMapping.lowercased()
        var words: [String] = []
        var current = ""
        for scalar in folded.unicodeScalars {
            if isCombiningMark(scalar) {
                continue
            } else if isKept(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        guard !words.isEmpty else { return nil }
        return truncate(words)
    }

    private static func isKept(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 0x61 && scalar.value <= 0x7A) || (scalar.value >= 0x30 && scalar.value <= 0x39)
    }

    /// Dropped rather than treated as a separator, so the `e` and the acute that NFD split out of
    /// `é` stay one word instead of becoming `re` and `sume`.
    private static func isCombiningMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    /// Whole words while they fit; a first word longer than the cap is cut mid-word so that a title
    /// with no separators still yields something.
    private static func truncate(_ words: [String]) -> String {
        var result = ""
        for word in words {
            let candidate = result.isEmpty ? word : result + "-" + word
            if candidate.count > maxLength {
                return result.isEmpty ? String(word.prefix(maxLength)) : result
            }
            result = candidate
        }
        return result
    }
}

/// SPEC §6.1. How this project names the branches it publishes. One `{slug}` is required; `{id}` is optional
/// and, when present, makes every published name unique by construction so no collision suffix is
/// ever added. Everything outside the placeholders is literal — `clay/{slug}` publishes under
/// `clay/`, which is also the namespace the remote policy confines writes to.
public struct RemoteBranchTemplate: Sendable, Equatable {
    public static let slugToken = "{slug}"
    public static let idToken = "{id}"

    public let raw: String

    /// Nil for empty text, for text with no `{slug}`, or for any `{…}` that is not a known token —
    /// a typo must not silently publish a branch with a literal brace in its name.
    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains(Self.slugToken) else { return nil }
        guard Self.placeholders(in: trimmed).allSatisfy({ $0 == Self.slugToken || $0 == Self.idToken })
        else { return nil }
        self.raw = trimmed
    }

    public var carriesId: Bool { raw.contains(Self.idToken) }

    /// The literal text before the first placeholder — `clay/` for `clay/{slug}`, empty for `{slug}`.
    /// `RemoteRefPolicy` refuses any published name that does not start with it.
    public var namespace: String {
        guard let brace = raw.firstIndex(of: "{") else { return raw }
        return String(raw[raw.startIndex..<brace])
    }

    public func render(slug: String, shortId: String) -> String {
        raw.replacingOccurrences(of: Self.slugToken, with: slug)
            .replacingOccurrences(of: Self.idToken, with: shortId)
    }

    private static func placeholders(in text: String) -> [String] {
        var found: [String] = []
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{") {
            guard let close = rest[open...].firstIndex(of: "}") else {
                found.append(String(rest[open...]))
                break
            }
            found.append(String(rest[open...close]))
            rest = rest[rest.index(after: close)...]
        }
        return found
    }
}

/// One thing Agent Board could publish: an epic or a task, reduced to what naming needs.
public struct PublishableRef: Sendable, Equatable {
    public var id: String
    public var title: String
    public var createdAt: Int64

    public init(id: String, title: String, createdAt: Int64) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
    }
}

public enum RemoteBranchNaming {
    /// 8 characters of a UUID — enough to separate the handful of same-titled records one project
    /// ever holds, short enough not to reintroduce the noise a slug exists to remove.
    public static let shortIdLength = 8

    public static func shortId(_ id: String) -> String {
        let usable = id.lowercased().unicodeScalars.filter {
            ($0.value >= 0x61 && $0.value <= 0x7A) || ($0.value >= 0x30 && $0.value <= 0x39)
        }
        let text = String(String.UnicodeScalarView(usable)).prefix(shortIdLength)
        return text.isEmpty ? "ref" : String(text)
    }

    /// The name `subject` is published under. `peers` is every other publishable ref in the project;
    /// when one of them slugs the same, the older record by `createdAt` (ties broken by id) keeps the
    /// bare slug and the newer takes a `-<short id>` suffix. Adding a third record never renames the
    /// first two, so a given task's published name is stable for the life of the board.
    public static func publishedName(
        for subject: PublishableRef, among peers: [PublishableRef], template: RemoteBranchTemplate
    ) -> String {
        let slug = BranchSlug.make(from: subject.title) ?? shortId(subject.id)
        guard !template.carriesId else {
            return template.render(slug: slug, shortId: shortId(subject.id))
        }
        let collides = peers.contains { peer in
            peer.id != subject.id
                && (BranchSlug.make(from: peer.title) ?? shortId(peer.id)) == slug
                && isOlder(peer, than: subject)
        }
        let body = collides ? "\(slug)-\(shortId(subject.id))" : slug
        return template.render(slug: body, shortId: shortId(subject.id))
    }

    private static func isOlder(_ lhs: PublishableRef, than rhs: PublishableRef) -> Bool {
        lhs.createdAt != rhs.createdAt ? lhs.createdAt < rhs.createdAt : lhs.id < rhs.id
    }
}

public enum RemoteRefPolicyError: Error, CustomStringConvertible, Equatable, Sendable {
    case empty
    case malformed(String)
    case isBaseBranch(String)
    case outsideNamespace(name: String, namespace: String)
    case qualifiedRef(String)

    public var description: String {
        switch self {
        case .empty:
            return "No published branch name was given."
        case .malformed(let name):
            return "\"\(name)\" is not a usable branch name on the remote."
        case .isBaseBranch(let name):
            return "Agent Board will not publish over the project's base branch \"\(name)\"."
        case .outsideNamespace(let name, let namespace):
            return "\"\(name)\" is outside \"\(namespace)\", the namespace this project's remote "
                + "branch template defines."
        case .qualifiedRef(let name):
            return "\"\(name)\" is a fully-qualified ref; the published name is a branch name."
        }
    }
}

/// SPEC §6.1. What may be written on the remote, a different question from what `PublishPolicy`
/// answers. `PublishPolicy` keeps guarding which *local* refs the tools may aim at — still only
/// `agentboard/…` and the base branch. This one guards the destination side of the refspec: the
/// name must be well-formed, must not be the base branch, and must sit inside the namespace the
/// project's template defines, so a template cannot be used to write an arbitrary remote branch.
public enum RemoteRefPolicy {
    @discardableResult
    public static func validate(
        published raw: String, template: RemoteBranchTemplate, baseBranch: String
    ) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw RemoteRefPolicyError.empty }
        guard !name.hasPrefix("refs/") else { throw RemoteRefPolicyError.qualifiedRef(name) }
        guard GitRefName.isWellFormed(name) else { throw RemoteRefPolicyError.malformed(name) }
        guard name != baseBranch.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw RemoteRefPolicyError.isBaseBranch(name)
        }
        let namespace = template.namespace
        guard name.hasPrefix(namespace), name.count > namespace.count else {
            throw RemoteRefPolicyError.outsideNamespace(name: name, namespace: namespace)
        }
        return name
    }
}
