import AgentBoardCore
import AppKit
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

    /// SPEC §10: At a Glance counts ready PRs only where follow-through is on, and its headline
    /// clause filters to the one project it counts but lists every project when it counts several.
    func testAtAGlanceCountsEnabledProjectsAndTheHeadlineFiltersOnlyToASoleProject() throws {
        let db = try AppDatabase.inMemory()
        let alpha = try project(db, name: "Alpha", label: nil)
        let beta = try project(db, name: "Beta", label: nil)
        var off = try project(db, name: "Off", label: nil)
        off.settings.prFollowThrough.enabled = false
        let counts = [
            alpha.id: PRBadgeCount(readyToVerify: 2), beta.id: PRBadgeCount(openDecisions: 1),
            off.id: PRBadgeCount(readyToVerify: 4),
        ]

        let ready = AtAGlanceView.readyToVerify(projects: [alpha, beta, off], counts: counts)
        XCTAssertEqual(ready, [alpha.id: 2])
        XCTAssertEqual(AtAGlanceView.headlineFilter(ready), alpha.id)
        XCTAssertNil(AtAGlanceView.headlineFilter([alpha.id: 2, beta.id: 1]))
    }

    func testEveryGroupShowsItsRowInPageOrder() throws {
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
        let lines = try recognizedLines(in: image, words: titles)
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
