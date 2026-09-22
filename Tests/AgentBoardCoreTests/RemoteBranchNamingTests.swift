import AgentBoardCore
import Foundation
import XCTest

final class BranchSlugTests: XCTestCase {
    func testATitleBecomesLowercaseHyphenatedWords() {
        XCTAssertEqual(
            BranchSlug.make(from: "Remove the non-working jsdom test-environment escape hatch from CLAUDE.md"),
            "remove-the-non-working-jsdom-test-environment"
        )
        XCTAssertEqual(BranchSlug.make(from: "Update CLAUDE.md"), "update-claude-md")
    }

    func testTheSameTitleSlugsIdenticallyEveryTime() {
        let title = "Push under a human-readable branch name instead of agentboard/epic-<uuid>"
        let runs = (0..<5).map { _ in BranchSlug.make(from: title) }
        XCTAssertEqual(Set(runs.map { $0 ?? "" }).count, 1)
        XCTAssertEqual(runs.first ?? nil, BranchSlug.make(from: title))
    }

    func testDiacriticsFoldToASCIIWithoutTransliteratingOtherScripts() {
        XCTAssertEqual(BranchSlug.make(from: "Café naïve résumé"), "cafe-naive-resume")
        XCTAssertNil(BranchSlug.make(from: "日本語のタイトル"))
        XCTAssertNil(BranchSlug.make(from: "🚀🔥"))
        XCTAssertNil(BranchSlug.make(from: "   "))
        XCTAssertNil(BranchSlug.make(from: ""))
    }

    func testTruncationStopsOnAWordBoundaryAndNeverExceedsTheCap() throws {
        let long = String(repeating: "alpha beta ", count: 40)
        let slug = try XCTUnwrap(BranchSlug.make(from: long))
        XCTAssertLessThanOrEqual(slug.count, BranchSlug.maxLength)
        XCTAssertFalse(slug.hasSuffix("-"))
        XCTAssertTrue(slug.hasPrefix("alpha-beta"), slug)
    }

    func testASingleWordLongerThanTheCapIsCutRatherThanDropped() throws {
        let slug = try XCTUnwrap(BranchSlug.make(from: String(repeating: "x", count: 300)))
        XCTAssertEqual(slug.count, BranchSlug.maxLength)
    }

    func testASlugCanNeverCarryTheCharactersGitRefusesOrThatEndARef() {
        let titles = [
            "feature/with/slashes", "\"quoted\" title", "trailing period.", "already.lock",
            "-leading dash", "a..b", "ref@{1}", "tab\tand\nnewline", "star*and?question",
            "back\\slash: colon", "~tilde^caret[bracket]", String(repeating: "long ", count: 80),
            "日本語 mixed 漢字 title", "emoji 🚀 title", "....", "---", "/",
        ]
        for title in titles {
            guard let slug = BranchSlug.make(from: title) else { continue }
            XCTAssertTrue(GitRefName.isWellFormed(slug), "\(title) -> \(slug)")
            XCTAssertFalse(slug.contains("."), "\(title) -> \(slug)")
            XCTAssertFalse(slug.hasPrefix("-") || slug.hasSuffix("-"), "\(title) -> \(slug)")
            XCTAssertLessThanOrEqual(slug.count, BranchSlug.maxLength, "\(title) -> \(slug)")
        }
    }
}

final class RemoteBranchTemplateTests: XCTestCase {
    func testATemplateMustCarryASlugAndNoUnknownPlaceholder() {
        XCTAssertNotNil(RemoteBranchTemplate("clay/{slug}"))
        XCTAssertNotNil(RemoteBranchTemplate("{slug}"))
        XCTAssertNotNil(RemoteBranchTemplate("clay/{slug}-{id}"))
        XCTAssertNil(RemoteBranchTemplate(""))
        XCTAssertNil(RemoteBranchTemplate("clay/no-placeholder"))
        XCTAssertNil(RemoteBranchTemplate("clay/{title}"))
        XCTAssertNil(RemoteBranchTemplate("clay/{slug}/{date}"))
        XCTAssertNil(RemoteBranchTemplate("clay/{slug"))
    }

    func testTheNamespaceIsTheLiteralTextBeforeTheFirstPlaceholder() {
        XCTAssertEqual(RemoteBranchTemplate("clay/{slug}")?.namespace, "clay/")
        XCTAssertEqual(RemoteBranchTemplate("agents/{id}-{slug}")?.namespace, "agents/")
        XCTAssertEqual(RemoteBranchTemplate("{slug}")?.namespace, "")
    }

    func testRenderingSubstitutesBothTokens() throws {
        let template = try XCTUnwrap(RemoteBranchTemplate("clay/{slug}-{id}"))
        XCTAssertEqual(template.render(slug: "fix-it", shortId: "a1b2c3d4"), "clay/fix-it-a1b2c3d4")
        XCTAssertTrue(template.carriesId)
        XCTAssertFalse(try XCTUnwrap(RemoteBranchTemplate("clay/{slug}")).carriesId)
    }
}

final class RemoteBranchCollisionTests: XCTestCase {
    private let template = RemoteBranchTemplate("clay/{slug}")!

    private func ref(_ id: String, _ title: String, _ createdAt: Int64) -> PublishableRef {
        PublishableRef(id: id, title: title, createdAt: createdAt)
    }

    func testATaskWithNoCollisionGetsNoIdSuffix() {
        let only = ref("11111111-aaaa", "Update CLAUDE.md", 100)
        let other = ref("22222222-bbbb", "Something else entirely", 200)
        XCTAssertEqual(
            RemoteBranchNaming.publishedName(for: only, among: [only, other], template: template),
            "clay/update-claude-md"
        )
    }

    func testTwoTasksThatSlugIdenticallyGetDistinctBranches() {
        let older = ref("11111111-aaaa", "Update CLAUDE.md", 100)
        let newer = ref("22222222-bbbb", "update claude md", 200)
        let peers = [older, newer]

        let first = RemoteBranchNaming.publishedName(for: older, among: peers, template: template)
        let second = RemoteBranchNaming.publishedName(for: newer, among: peers, template: template)

        XCTAssertEqual(first, "clay/update-claude-md")
        XCTAssertEqual(second, "clay/update-claude-md-22222222")
        XCTAssertNotEqual(first, second)
    }

    func testAThirdCollidingRecordNeverRenamesTheFirstTwo() {
        let a = ref("aaaaaaaa-1", "Same title", 100)
        let b = ref("bbbbbbbb-2", "Same title", 200)
        let c = ref("cccccccc-3", "Same title", 300)

        XCTAssertEqual(RemoteBranchNaming.publishedName(for: a, among: [a, b], template: template), "clay/same-title")
        XCTAssertEqual(
            RemoteBranchNaming.publishedName(for: a, among: [a, b, c], template: template), "clay/same-title"
        )
        XCTAssertEqual(
            RemoteBranchNaming.publishedName(for: b, among: [a, b], template: template), "clay/same-title-bbbbbbbb"
        )
        XCTAssertEqual(
            RemoteBranchNaming.publishedName(for: b, among: [a, b, c], template: template), "clay/same-title-bbbbbbbb"
        )
        XCTAssertEqual(
            RemoteBranchNaming.publishedName(for: c, among: [a, b, c], template: template), "clay/same-title-cccccccc"
        )
    }

    func testEqualTimestampsAreBrokenByIdSoTheAnswerIsStillDeterministic() {
        let a = ref("aaaaaaaa-1", "Tie", 100)
        let b = ref("bbbbbbbb-2", "Tie", 100)
        XCTAssertEqual(RemoteBranchNaming.publishedName(for: a, among: [a, b], template: template), "clay/tie")
        XCTAssertEqual(
            RemoteBranchNaming.publishedName(for: b, among: [a, b], template: template), "clay/tie-bbbbbbbb"
        )
    }

    func testATemplateCarryingTheIdNeverAddsACollisionSuffix() {
        let withId = RemoteBranchTemplate("clay/{slug}-{id}")!
        let a = ref("aaaaaaaa-1", "Same title", 100)
        let b = ref("bbbbbbbb-2", "Same title", 200)
        XCTAssertEqual(
            RemoteBranchNaming.publishedName(for: b, among: [a, b], template: withId), "clay/same-title-bbbbbbbb"
        )
    }

    func testATitleThatSlugsToNothingFallsBackToTheShortId() {
        let emoji = ref("deadbeef-cafe", "🚀", 100)
        XCTAssertEqual(
            RemoteBranchNaming.publishedName(for: emoji, among: [emoji], template: template), "clay/deadbeef"
        )
        let blank = ref("00ff00ff-0000", "", 100)
        XCTAssertEqual(
            RemoteBranchNaming.publishedName(for: blank, among: [blank], template: template), "clay/00ff00ff"
        )
    }
}

final class RemoteRefPolicyTests: XCTestCase {
    private let template = RemoteBranchTemplate("clay/{slug}")!

    func testItAcceptsANameInsideTheTemplatesNamespace() throws {
        XCTAssertEqual(
            try RemoteRefPolicy.validate(published: "clay/fix-it", template: template, baseBranch: "main"),
            "clay/fix-it"
        )
    }

    func testItRefusesTheBaseBranch() {
        let flat = RemoteBranchTemplate("{slug}")!
        XCTAssertThrowsError(try RemoteRefPolicy.validate(published: "main", template: flat, baseBranch: "main")) {
            XCTAssertEqual($0 as? RemoteRefPolicyError, .isBaseBranch("main"))
        }
        XCTAssertThrowsError(
            try RemoteRefPolicy.validate(published: " main ", template: flat, baseBranch: "main")
        )
    }

    func testItRefusesANameOutsideTheTemplatesNamespace() {
        for name in ["main", "someone-else/fix-it", "clay", "agentboard/epic-7"] {
            XCTAssertThrowsError(
                try RemoteRefPolicy.validate(published: name, template: template, baseBranch: "trunk"),
                name
            )
        }
    }

    func testItRefusesMalformedNamesAndQualifiedRefs() {
        for name in ["", "   ", "clay/a..b", "clay/a:b", "clay/a b", "clay/x.lock", "clay/trailing.",
                     "clay//double", "clay/a@{1}"] {
            XCTAssertThrowsError(
                try RemoteRefPolicy.validate(published: name, template: template, baseBranch: "main"), name
            )
        }
        XCTAssertThrowsError(
            try RemoteRefPolicy.validate(
                published: "refs/heads/clay/x", template: RemoteBranchTemplate("refs/{slug}")!, baseBranch: "main"
            )
        ) {
            XCTAssertEqual($0 as? RemoteRefPolicyError, .qualifiedRef("refs/heads/clay/x"))
        }
    }

    /// Every title the slugger is asked to survive, rendered through a template and put past the
    /// policy that guards the remote.
    func testEveryHostileTitleRendersToANameThePolicyAccepts() throws {
        let titles = [
            "feature/with/slashes", "\"quoted\" title", "trailing period.", "already.lock",
            "-leading dash", "日本語のタイトル", "emoji 🚀 title", String(repeating: "x", count: 300),
            "A very long title: " + String(repeating: "word ", count: 80),
            "tab\tnewline\ncolon:star*", "~^[]\\?", "....", "---",
        ]
        for (index, title) in titles.enumerated() {
            let subject = PublishableRef(
                id: "\(index)0abcdef-1111-2222-3333-444444444444", title: title, createdAt: Int64(index)
            )
            let name = RemoteBranchNaming.publishedName(for: subject, among: [subject], template: template)
            XCTAssertNoThrow(
                try RemoteRefPolicy.validate(published: name, template: template, baseBranch: "main"), "\(title)"
            )
            XCTAssertTrue(name.hasPrefix("clay/"), name)
        }
    }

    /// The local guard is a different question and keeps its own answer: `clay/…` is not a branch
    /// Agent Board owns locally, and `agentboard/…` is.
    func testTheLocalPolicyIsUnchangedByTheRemoteOne() throws {
        XCTAssertThrowsError(try PublishPolicy.validate(branch: "clay/fix-it", baseBranch: "main"))
        XCTAssertEqual(try PublishPolicy.validate(branch: "agentboard/epic-7", baseBranch: "main"), "agentboard/epic-7")
        XCTAssertThrowsError(
            try RemoteRefPolicy.validate(published: "agentboard/epic-7", template: template, baseBranch: "main")
        )
    }
}

final class PublishRequestPublishedBranchTests: XCTestCase {
    func testHeadIsThePublishedNameWhenThereIsOneAndTheLocalNameOtherwise() {
        XCTAssertEqual(PublishRequest(branch: "agentboard/t1").head, "agentboard/t1")
        XCTAssertEqual(
            PublishRequest(branch: "agentboard/t1", publishedBranch: "clay/fix-it").head, "clay/fix-it"
        )
    }

    func testAPayloadWrittenBeforeRemoteNamingStillDecodes() throws {
        let legacy = #"{"branch":"agentboard/epic-7","base":"main","remote":"origin","title":"T","body":"B"}"#
        let request = try PublishRequest.decode(legacy)
        XCTAssertEqual(request.branch, "agentboard/epic-7")
        XCTAssertNil(request.publishedBranch)
        XCTAssertEqual(request.head, "agentboard/epic-7")
        XCTAssertEqual(request.remote, "origin")
    }

    func testARoundTripKeepsThePublishedName() throws {
        let request = PublishRequest(
            branch: "agentboard/t1", base: "main", title: "T", body: "B", publishedBranch: "clay/fix-it"
        )
        XCTAssertEqual(try PublishRequest.decode(try request.encoded()), request)
    }
}

final class ProjectSettingsRemoteTemplateTests: XCTestCase {
    func testANewProjectSetsNoTemplate() {
        XCTAssertNil(ProjectSettings().remoteBranchTemplate)
        XCTAssertNil(ProjectSettings.forNewProject().remoteBranchTemplate)
    }

    func testASettingsRowWrittenBeforeThisChangeStillDecodes() {
        let legacy = """
        {"archivePolicy":{"mode":"afterEpicMerge"},"autonomyEnabled":true,"caps":{"maxConcurrentWorkers":5,\
        "maxIdleSeconds":300,"maxWallClockSeconds":1800,"shutdownGraceSeconds":120,"stallSeconds":120},\
        "extraMcpServers":[],"sharedCheckoutMaxAgents":3,"worktreeStrategy":"worktree"}
        """
        let settings = ProjectSettings.decode(legacy)
        XCTAssertNil(settings.remoteBranchTemplate)
        XCTAssertTrue(settings.autonomyEnabled)
        XCTAssertEqual(settings.caps.maxConcurrentWorkers, 5)
    }

    func testTheTemplateSurvivesARoundTrip() {
        var settings = ProjectSettings()
        settings.remoteBranchTemplate = "clay/{slug}"
        XCTAssertEqual(ProjectSettings.decode(settings.encoded()).remoteBranchTemplate, "clay/{slug}")
    }
}
