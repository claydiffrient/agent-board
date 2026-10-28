import AgentBoardCore
import AgentBoardRuntime
import AppKit
import GRDB
import SwiftUI
import Vision
import XCTest
@testable import AgentBoard

/// SPEC §13.4: the Pull Requests page, its row actions, and the sidebar row's badge.
@MainActor
final class PullRequestsPageTests: XCTestCase {
    private let label = "verified-example"

    private func project(_ db: AppDatabase, name: String = "app", label: String?) throws -> Project {
        var project = try ProjectStore(db).register(
            name: name, repoPath: "/tmp/pr-page-\(UUID().uuidString)", baseBranch: "main",
            worktreeRoot: "/tmp/pr-page-worktrees", memoryDir: nil
        )
        project.settings.prFollowThrough = PRFollowThroughSettings(enabled: true, verificationLabel: label)
        try ProjectStore(db).updateSettings(project.id, project.settings)
        return project
    }

    @discardableResult
    private func watch(
        _ db: AppDatabase, _ project: Project, number: Int, title: String, state: PRWatchState,
        decision: Bool = false
    ) throws -> PRWatch {
        let store = PRWatchStore(db)
        let created = try store.upsert(projectId: project.id, snapshot: PRSnapshot(
            repoOwner: "example-org", repoName: "app", number: number,
            url: "https://github.com/example-org/app/pull/\(number)", title: title,
            headRef: "branch-\(number)", headOid: "c0ffee", baseRef: "main",
            items: decision ? [PRSnapshotItem(githubNodeId: "D\(number)", kind: .thread, body: "Which way?")] : []
        ))
        try store.setState(state, watchId: created.id)
        if decision {
            try db.writer.write {
                try $0.execute(sql: "UPDATE pr_item SET verdict = 'decision' WHERE watch_id = ?", arguments: [created.id])
            }
        }
        return try XCTUnwrap(store.get(created.id))
    }

    /// SPEC §13.4: the sidebar badge and At a Glance read one count, and it leaves out a project that
    /// turned follow-through off with ready watches still stored. The headline clause filters to the
    /// one project it counts but lists every project when it counts several.
    func testOnlyProjectsWithFollowThroughOnCountTowardTheBadgeAndAtAGlance() throws {
        let db = try AppDatabase.inMemory()
        let alpha = try project(db, name: "Alpha", label: nil)
        var off = try project(db, name: "Off", label: nil)
        try watch(db, alpha, number: 1, title: "One", state: .readyToVerify)
        try watch(db, off, number: 2, title: "Two", state: .readyToVerify)
        try watch(db, off, number: 3, title: "Three", state: .watching, decision: true)
        off.settings.prFollowThrough.enabled = false
        try ProjectStore(db).updateSettings(off.id, off.settings)

        let counts = try PRWatchStore(db).badgeCounts()
        XCTAssertEqual(PullRequestsRow.count(counts), 1)
        let ready = AtAGlanceView.readyToVerify(counts)
        XCTAssertEqual(ready, [alpha.id: 1])
        XCTAssertEqual(AtAGlanceView.headlineFilter(ready), alpha.id)
        XCTAssertNil(AtAGlanceView.headlineFilter([alpha.id: 2, off.id: 1]))
    }

    @discardableResult
    private func decision(
        _ db: AppDatabase, _ project: Project, number: Int, question: String, options: [PRDecisionOption]
    ) throws -> PRItem {
        let store = PRWatchStore(db)
        let created = try store.upsert(projectId: project.id, snapshot: PRSnapshot(
            repoOwner: "example-org", repoName: "app", number: number,
            url: "https://github.com/example-org/app/pull/\(number)", title: "Pull \(number)",
            headRef: "branch-\(number)", headOid: "c0ffee", baseRef: "main",
            items: [PRSnapshotItem(
                githubNodeId: "D\(number)", kind: .thread, author: "reviewer", body: "Should this block the caller?"
            )]
        ))
        let item = try XCTUnwrap(try store.openItems(watchId: created.id).first)
        try store.setVerdicts([PRVerdictInput(
            itemId: try XCTUnwrap(item.id), verdict: .decision, approach: "Direction.",
            decisionQuestion: question, decisionOptions: options
        )], watchId: created.id)
        try store.setState(.watching, watchId: created.id)
        return try XCTUnwrap(try store.openItems(watchId: created.id).first)
    }

    func testANeedsYouRowShowsTheCommentTheQuestionAnOptionButtonEachAndAReplyField() throws {
        let db = try AppDatabase.inMemory()
        let project = try project(db, label: label)
        try decision(db, project, number: 7, question: "Which concurrency model?", options: [
            PRDecisionOption(label: "Asynchronous", verdict: .fix),
            PRDecisionOption(label: "Blocking", verdict: .answer, replyBody: "The caller needs the result."),
        ])

        let mount = OffscreenMount(
            PullRequestsView(projects: [project]).environment(renderEnvironment(db: db)),
            size: CGSize(width: 900, height: 800)
        )
        defer { mount.close() }
        // The Needs you row plus the empty Ready to verify, In progress, Waiting and Verified placeholders.
        _ = try mount.capture(showing: SidebarContent(rows: 5, headers: 5))
        let shot = try XCTUnwrap(CGWindowListCreateImage(
            .null, .optionIncludingWindow, CGWindowID(mount.window.windowNumber),
            [.boundsIgnoreFraming, .bestResolution]
        ))
        let words = ["concurrency", "Asynchronous", "Blocking", "caller"]
        let text = try recognizedLines(in: shot, words: words).map(\.text).joined(separator: " | ")
        for word in words {
            XCTAssertTrue(text.localizedCaseInsensitiveContains(word), "\(word) not drawn: \(text)")
        }
        let fields = textFields(in: mount.host).filter(\.isEditable)
        XCTAssertEqual(fields.map(\.placeholderString), ["Reply instead"])
    }

    /// An option answers a decision with its own verdict: a fix stays open for the next round with no
    /// task, an answer is handled with the option's reply, and a typed reply answers it in words. Each leaves the badge
    /// and the attention signal and moves to the next round. `chosen` keeps the old string-only options,
    /// which read as fix.
    func testAnsweringADecisionClearsItsSignalsAndMovesItToTheNextRound() throws {
        let db = try AppDatabase.inMemory()
        let project = try project(db, label: label)
        let options = [
            PRDecisionOption(label: "Change the helper", verdict: .fix),
            PRDecisionOption(label: "Keep it local", verdict: .answer, replyBody: "Only one caller uses it."),
        ]
        let chosen = try decision(db, project, number: 7, question: "Which model?", options: options)
        let kept = try decision(db, project, number: 8, question: "Share the helper?", options: options)
        let replied = try decision(db, project, number: 9, question: "Rename it?", options: options)
        try db.writer.write { db in
            try db.execute(
                sql: #"UPDATE pr_item SET decision_options_json = '["Change the helper","Keep it local"]' WHERE id = ?"#,
                arguments: [chosen.id]
            )
        }
        XCTAssertEqual(try PRWatchStore(db).badgeCounts()[project.id]?.openDecisions, 3)
        let cause = try XCTUnwrap(try ProjectAttentionStore(db).attention(projectId: project.id)?
            .cause(.pullRequestDecision))
        XCTAssertTrue(cause.text.contains("3 pull request decisions"), cause.text)

        let actions = PullRequestActions(db: db, gh: FakeGh())
        try actions.answer(chosen, choice: .option("Change the helper"))
        try actions.answer(kept, choice: .option("Keep it local"))
        try actions.answer(replied, choice: .reply("The old name is public API."))

        XCTAssertNil(try PRWatchStore(db).badgeCounts()[project.id])
        XCTAssertNil(try ProjectAttentionStore(db).attention(projectId: project.id)?.cause(.pullRequestDecision))
        let fix = try XCTUnwrap(try PRWatchStore(db).items(watchId: chosen.watchId).first)
        XCTAssertEqual(fix.state, .open)
        XCTAssertEqual(fix.verdict, .fix)
        XCTAssertEqual(fix.decisionAnswer, "Change the helper")
        XCTAssertEqual(fix.approach, "Change the helper")
        XCTAssertEqual(fix.round, chosen.round + 1)
        XCTAssertNil(fix.fixTaskId)

        let local = try XCTUnwrap(try PRWatchStore(db).items(watchId: kept.watchId).first)
        XCTAssertEqual(local.state, .handled)
        XCTAssertEqual(local.verdict, .answer)
        XCTAssertEqual(local.decisionAnswer, "Keep it local")
        XCTAssertEqual(local.replyBody, "Only one caller uses it.")
        XCTAssertNil(local.fixTaskId)
        XCTAssertEqual(try TaskStore(db).list(projectId: project.id).filter { $0.origin == .followThrough }, [])

        let answer = try XCTUnwrap(try PRWatchStore(db).items(watchId: replied.watchId).first)
        XCTAssertEqual(answer.state, .handled)
        XCTAssertEqual(answer.verdict, .answer)
        XCTAssertEqual(answer.replyBody, "The old name is public API.")
        XCTAssertNil(answer.fixTaskId)
    }

    /// SPEC §13.4: each group's header carries its Refresh button, and a row says when it was last polled.
    func testEveryGroupShowsItsRowInPageOrderUnderAHeaderWithRefresh() throws {
        let db = try AppDatabase.inMemory()
        let project = try project(db, label: label)
        let titles = ["Avocado", "Broccoli", "Carrot", "Daikon", "Eggplant", "Fennel"]
        try watch(db, project, number: 1, title: titles[0], state: .readyToVerify)
        try watch(db, project, number: 2, title: titles[1], state: .watching, decision: true)
        try watch(db, project, number: 3, title: titles[2], state: .settling)
        try watch(db, project, number: 4, title: titles[3], state: .watching)
        try watch(db, project, number: 5, title: titles[4], state: .verified)
        try watch(db, project, number: 6, title: titles[5], state: .parked)

        let mount = OffscreenMount(
            PullRequestsView(projects: [project]).environment(renderEnvironment(db: db)),
            size: CGSize(width: 900, height: 800)
        )
        defer { mount.close() }
        _ = try mount.capture(showing: SidebarContent(rows: 6, headers: 6))
        XCTAssertEqual(mount.sidebarContent, SidebarContent(rows: 6, headers: 6), "one header and one row per group")

        let image = try XCTUnwrap(CGWindowListCreateImage(
            .null, .optionIncludingWindow, CGWindowID(mount.window.windowNumber),
            [.boundsIgnoreFraming, .bestResolution]
        ))
        let lines = try recognizedLines(in: image, words: titles + ["Refresh", "polled"])
        let text = lines.map(\.text).joined(separator: " | ")
        XCTAssertEqual(text.lowercased().components(separatedBy: "refresh").count - 1, 6, "one Refresh per header: \(text)")
        XCTAssertTrue(text.contains("polled"), "no row shows when it was polled: \(text)")
        let heights = try titles.map { title in
            try XCTUnwrap(
                lines.first { $0.text.localizedCaseInsensitiveContains(title) }?.box.midY,
                "\(title) not drawn: \(lines.map(\.text))"
            )
        }
        XCTAssertEqual(heights, heights.sorted(by: >), "rows out of group order: \(zip(titles, heights).map { "\($0) \($1)" })")
    }

    func testNeedsYouAndParkedAreHiddenWhileEmptyAndTheOtherGroupsAreNot() throws {
        let db = try AppDatabase.inMemory()
        let project = try project(db, label: label)
        try watch(db, project, number: 1, title: "Avocado", state: .readyToVerify)
        try watch(db, project, number: 2, title: "Daikon", state: .watching)

        let mount = OffscreenMount(
            PullRequestsView(projects: [project]).environment(renderEnvironment(db: db)),
            size: CGSize(width: 900, height: 800)
        )
        defer { mount.close() }
        // Two rows plus the empty In progress and Verified groups' placeholder lines.
        _ = try mount.capture(showing: SidebarContent(rows: 4, headers: 4))
        XCTAssertEqual(mount.sidebarContent, SidebarContent(rows: 4, headers: 4))
    }

    /// SPEC §13.4: a parked row shows why, and offers Resume and Stop watching in place of Pause.
    func testAParkedRowShowsItsReasonWithResumeAndStopWatching() throws {
        let db = try AppDatabase.inMemory()
        let project = try project(db, label: label)
        let parked = try watch(db, project, number: 6, title: "Fennel", state: .parked)
        try db.writer.write {
            try $0.execute(
                sql: "UPDATE pr_watch SET parked_reason = ? WHERE id = ?",
                arguments: ["#6 has run its round cap of 3 rounds without the feedback settling.", parked.id]
            )
        }

        let mount = OffscreenMount(
            PullRequestsView(projects: [project]).environment(renderEnvironment(db: db)),
            size: CGSize(width: 900, height: 800)
        )
        defer { mount.close() }
        // The Parked row plus the empty Ready to verify, In progress, Waiting and Verified placeholders.
        _ = try mount.capture(showing: SidebarContent(rows: 5, headers: 5))
        let shot = try XCTUnwrap(CGWindowListCreateImage(
            .null, .optionIncludingWindow, CGWindowID(mount.window.windowNumber),
            [.boundsIgnoreFraming, .bestResolution]
        ))
        let words = ["Parked", "Fennel", "round cap", "Resume", "Stop watching"]
        let text = try recognizedLines(in: shot, words: words).map(\.text).joined(separator: " | ")
        for word in words {
            XCTAssertTrue(text.localizedCaseInsensitiveContains(word), "\(word) not drawn: \(text)")
        }
        XCTAssertFalse(text.localizedCaseInsensitiveContains("Pause"), "a parked row has no Pause: \(text)")
    }

    func testMarkVerifiedAddsTheConfiguredLabelThroughGhAndNothingRunsWithoutOne() async throws {
        let db = try AppDatabase.inMemory()
        let labeled = try project(db, label: label)
        let unlabeled = try project(db, name: "other", label: nil)
        let ready = try watch(db, labeled, number: 12, title: "Add widgets", state: .readyToVerify)
        let gh = FakeGh()
        gh.answer(ready.url, state: "OPEN")
        let actions = PullRequestActions(db: db, gh: gh)

        try await actions.markVerified(ready, project: labeled)
        XCTAssertEqual(gh.calls, [["pr", "edit", ready.url, "--add-label", label]])
        let verified = try XCTUnwrap(PRWatchStore(db).get(ready.id))
        XCTAssertEqual(verified.state, .verified)
        XCTAssertEqual(verified.labels, [label])

        let elsewhere = try watch(db, unlabeled, number: 13, title: "Fix widgets", state: .readyToVerify)
        try await actions.markVerified(elsewhere, project: unlabeled)
        XCTAssertEqual(gh.calls.count, 1, "a project with no label has nothing to add")
        XCTAssertEqual(try PRWatchStore(db).get(elsewhere.id)?.state, .readyToVerify)
    }

    func testTheVerifyCommandRunsInAnInteractiveLoginShellInTheCheckout() throws {
        let db = try AppDatabase.inMemory()
        var project = try project(db, label: label)
        project.settings.prFollowThrough.verifyCommand = #"claude "/review:verify {url}""#
        let watch = try watch(db, project, number: 7, title: "Seven", state: .readyToVerify)

        let configDir = FileManager.default.temporaryDirectory.appendingPathComponent("pr-verify-\(UUID().uuidString)")
        let verifier = VerifierLaunch(db: db, configDir: configDir, port: 4242)

        let command = try XCTUnwrap(PRVerifyCommand.make(
            watch: watch, project: project, verifier: verifier, base: ["SHELL": "/bin/zsh"]
        ))
        XCTAssertEqual(command.executable, "/bin/zsh")
        XCTAssertEqual(command.execName, "-zsh")
        XCTAssertEqual(command.arguments, ["-i", "-c", #"claude "/review:verify https://github.com/example-org/app/pull/7""#])
        XCTAssertEqual(command.directory, project.repoPath)
        XCTAssertNil(command.lease, "no {mcp_config}, no grant")
        XCTAssertEqual(try verifierGrants(db), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: configDir.path), "no {mcp_config}, no file")
    }

    func testAVerifyCommandNamingMCPConfigGetsAProposeOnlyGrantThroughAFileOnItsCommandLine() throws {
        let db = try AppDatabase.inMemory()
        var project = try project(db, label: label)
        project.settings.prFollowThrough.verifyCommand = #"claude "/review:verify {url}" --mcp-config {mcp_config}"#
        let watch = try watch(db, project, number: 7, title: "Seven", state: .readyToVerify)
        let configDir = FileManager.default.temporaryDirectory.appendingPathComponent("pr-verify-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: configDir) }
        let base = ["SHELL": "/bin/zsh", "AGENTBOARD_SUPPORT_DIR": "/support", "AGENTBOARD_TOKEN": "worker-token"]

        let command = try XCTUnwrap(PRVerifyCommand.make(
            watch: watch, project: project, verifier: VerifierLaunch(db: db, configDir: configDir, port: 4242), base: base
        ))
        let lease = try XCTUnwrap(command.lease)
        let grants = try verifierGrants(db)
        XCTAssertEqual(grants.map(\.token), [lease.token])
        XCTAssertEqual(grants.first?.projectId, project.id)
        XCTAssertEqual(grants.first?.prWatchId, watch.id)

        let path = lease.configURL.path
        XCTAssertEqual(command.arguments, [
            "-i", "-c", #"claude "/review:verify https://github.com/example-org/app/pull/7" --mcp-config '\#(path)'"#,
        ])
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: lease.configURL)) as? [String: Any])
        let server = try XCTUnwrap((config["mcpServers"] as? [String: Any])?["agent-board"] as? [String: Any])
        XCTAssertEqual(server["url"] as? String, "http://127.0.0.1:4242/mcp")
        XCTAssertEqual((server["headers"] as? [String: String])?["Authorization"], "Bearer \(lease.token)")

        let keys = command.environment.map { String($0.prefix { $0 != "=" }) }
        XCTAssertTrue(Set(keys).isDisjoint(with: ChildEnvironment.boardAuthorityVariables))
        XCTAssertFalse(command.environment.contains { $0.contains(path) || $0.contains(lease.token) })

        lease.release()
        lease.release()
        XCTAssertNotNil(try TokenGrantStore(db).lookup(token: lease.token)?.revokedAt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testLaunchRevokesEveryVerifierGrantAndDeletesEveryLeftoverConfig() async throws {
        let fixture = try SupervisorFixture.make()
        let project = try project(fixture.db, label: label)
        let watch = try watch(fixture.db, project, number: 7, title: "Seven", state: .readyToVerify)
        let configDir = SessionConfigWriter.configDir(supportDir: fixture.supportDir)
        let leftover = try VerifierLaunch(db: fixture.db, configDir: configDir, port: 4242)
            .lease(projectId: project.id, prWatchId: watch.id)

        await fixture.supervisor.start()
        XCTAssertEqual(try verifierGrants(fixture.db), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.configURL.path))
        await fixture.cleanUp()
    }

    private func verifierGrants(_ db: AppDatabase) throws -> [TokenGrant] {
        try db.reader.read {
            try TokenGrant.filter(Column("scope") == TokenScope.verifier.rawValue && Column("revoked_at") == nil).fetchAll($0)
        }
    }

    func testAVerifyCommandTypedAsASlashCommandGetsTheClaudeHintOnlyWhenTheShellFailsFast() {
        let template = "/review:verify {url}"
        let missing: (String) -> Bool = { _ in false }
        XCTAssertEqual(
            PRVerifyCommand.slashCommandHint(template: template, exitCode: 127, elapsed: .milliseconds(40), fileExists: missing),
            #"/review:verify is a slash command, which only runs inside Claude. Set the verify command to claude "/review:verify {url}" --mcp-config {mcp_config} to run it there."#
        )
        XCTAssertNil(PRVerifyCommand.slashCommandHint(template: template, exitCode: 0, elapsed: .milliseconds(40), fileExists: missing))
        XCTAssertNil(PRVerifyCommand.slashCommandHint(template: template, exitCode: 1, elapsed: .seconds(5), fileExists: missing))
        XCTAssertNil(PRVerifyCommand.slashCommandHint(
            template: template, exitCode: 1, elapsed: .milliseconds(40), fileExists: { _ in true }
        ))
        XCTAssertNil(PRVerifyCommand.slashCommandHint(
            template: "/usr/local/bin/verify {url}", exitCode: 127, elapsed: .milliseconds(40), fileExists: missing
        ))
    }

    func testTheSidebarBadgeCountsThePullRequestsReadyToVerify() throws {
        let db = try AppDatabase.inMemory()
        let first = try project(db, label: label)
        let second = try project(db, name: "other", label: label)
        try watch(db, first, number: 1, title: "One", state: .readyToVerify)
        try watch(db, second, number: 2, title: "Two", state: .readyToVerify)
        try watch(db, first, number: 3, title: "Three", state: .watching)
        try watch(db, first, number: 4, title: "Four", state: .verified)
        try watch(db, second, number: 5, title: "Five", state: .settling)

        XCTAssertEqual(PullRequestsRow.count(try PRWatchStore(db).badgeCounts()), 2)
    }

    private func textFields(in root: NSView) -> [NSTextField] {
        var found: [NSTextField] = []
        var queue = [root]
        while let view = queue.popLast() {
            if let field = view as? NSTextField { found.append(field) }
            queue.append(contentsOf: view.subviews)
        }
        return found
    }

    private struct Line {
        let text: String
        let box: CGRect
    }

    private func recognizedLines(in image: CGImage, words: [String]) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.customWords = words
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { Line(text: $0.string, box: observation.boundingBox) }
        }
    }
}
