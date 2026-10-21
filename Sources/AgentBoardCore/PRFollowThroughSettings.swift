import Foundation

/// Which agent fills one follow-through role. Both nil leaves the choice to the app's default.
public struct PRFollowThroughRole: Codable, Sendable, Equatable {
    public var rosterAgentId: String?
    public var model: String?

    public init(rosterAgentId: String? = nil, model: String? = nil) {
        self.rosterAgentId = rosterAgentId
        self.model = model
    }
}

public struct PRFollowThroughRoles: Codable, Sendable, Equatable {
    public var triage: PRFollowThroughRole?
    public var fixer: PRFollowThroughRole?
    public var reviewer: PRFollowThroughRole?
    public var followupCheck: PRFollowThroughRole?

    public init(
        triage: PRFollowThroughRole? = nil, fixer: PRFollowThroughRole? = nil,
        reviewer: PRFollowThroughRole? = nil, followupCheck: PRFollowThroughRole? = nil
    ) {
        self.triage = triage
        self.fixer = fixer
        self.reviewer = reviewer
        self.followupCheck = followupCheck
    }
}

/// `settings_json.prFollowThrough` (SPEC §4). Every work-specific value lives here, never in a code
/// default, so everything starts off or empty.
public struct PRFollowThroughSettings: Codable, Sendable, Equatable {
    public var enabled: Bool = false
    /// Nil makes the user's merge the verification.
    public var verificationLabel: String? = nil
    public var requireApproval: Bool = true
    public var settleMinutes: Int = 10
    public var roundCap: Int = 3
    /// Nil uses the project's spawn caps instead of a dollar budget.
    public var dailyBudgetUSD: Double? = nil
    /// A command template with `{url}`, run by "Walk me through it".
    public var verifyCommand: String? = nil
    public var postFactualReplies: Bool = false
    public var roles: PRFollowThroughRoles = PRFollowThroughRoles()
    /// Matched case-insensitively by the publish guard.
    public var privateTerms: [String] = []

    public init(
        enabled: Bool = false,
        verificationLabel: String? = nil,
        requireApproval: Bool = true,
        settleMinutes: Int = 10,
        roundCap: Int = 3,
        dailyBudgetUSD: Double? = nil,
        verifyCommand: String? = nil,
        postFactualReplies: Bool = false,
        roles: PRFollowThroughRoles = PRFollowThroughRoles(),
        privateTerms: [String] = []
    ) {
        self.enabled = enabled
        self.verificationLabel = verificationLabel
        self.requireApproval = requireApproval
        self.settleMinutes = settleMinutes
        self.roundCap = roundCap
        self.dailyBudgetUSD = dailyBudgetUSD
        self.verifyCommand = verifyCommand
        self.postFactualReplies = postFactualReplies
        self.roles = roles
        self.privateTerms = privateTerms
    }

    /// The label Mark verified adds, or nil when none is set and the merge is the verification.
    public var markVerifiedLabel: String? {
        let label = verificationLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return label.isEmpty ? nil : label
    }

    /// `verifyCommand` with `{url}` replaced, for Walk me through it. Nil without a template, and for
    /// a URL holding anything a shell would read as syntax: the template is run by a shell as written.
    public func verifyCommand(for url: String) -> String? {
        let template = verifyCommand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !template.isEmpty, !url.isEmpty, url.allSatisfy(Self.isShellInert) else { return nil }
        return template.replacingOccurrences(of: "{url}", with: url)
    }

    private static func isShellInert(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || ":/._-".contains(c))
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PRFollowThroughSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        verificationLabel = try c.decodeIfPresent(String.self, forKey: .verificationLabel)
        requireApproval = try c.decodeIfPresent(Bool.self, forKey: .requireApproval) ?? defaults.requireApproval
        settleMinutes = try c.decodeIfPresent(Int.self, forKey: .settleMinutes) ?? defaults.settleMinutes
        roundCap = try c.decodeIfPresent(Int.self, forKey: .roundCap) ?? defaults.roundCap
        dailyBudgetUSD = try c.decodeIfPresent(Double.self, forKey: .dailyBudgetUSD)
        verifyCommand = try c.decodeIfPresent(String.self, forKey: .verifyCommand)
        postFactualReplies = try c.decodeIfPresent(Bool.self, forKey: .postFactualReplies) ?? defaults.postFactualReplies
        roles = try c.decodeIfPresent(PRFollowThroughRoles.self, forKey: .roles) ?? defaults.roles
        privateTerms = try c.decodeIfPresent([String].self, forKey: .privateTerms) ?? defaults.privateTerms
    }
}
