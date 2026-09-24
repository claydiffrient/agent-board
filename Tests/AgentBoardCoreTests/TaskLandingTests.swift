import Foundation
import XCTest
@testable import AgentBoardCore

/// SPEC §5: `done` carries a landing, and the value it defaults to is the one that asks for
/// attention. The silent case — `done` with no statement about where the work went — is what put
/// seven tasks' commits on branches nobody looked at again.
final class TaskLandingTests: XCTestCase {
    func testReachingDoneArmsPendingSoNoRouteIntoTheColumnIsSilent() throws {
        let f = try Fixture.make()
        let accepted = try f.task("Accepted", column: .review)
        let dragged = try f.task("Dragged across the board", column: .review)

        try f.board.accept(taskId: accepted.id)
        try f.tasks.move(dragged.id, to: .done)

        for id in [accepted.id, dragged.id] {
            let task = try XCTUnwrap(try f.tasks.get(id))
            XCTAssertEqual(task.column, .done)
            XCTAssertEqual(task.landing, .pending, "a task reached done without arming its landing")
            XCTAssertTrue(task.needsLanding)
        }
        XCTAssertEqual(
            try f.tasks.awaitingLanding(projectId: f.project.id).map(\.id).sorted(),
            [accepted.id, dragged.id].sorted()
        )
    }

    /// The crash window: the accept transaction committed, the git half never ran. The board has to
    /// keep saying it does not know rather than settle on "landed".
    func testAPendingLandingIsNeverSilentlyTreatedAsSettled() throws {
        let f = try Fixture.make()
        let task = try f.task("Accepted then the app died", column: .review)
        try f.board.accept(taskId: task.id)

        let stranded = try XCTUnwrap(try f.tasks.get(task.id))
        XCTAssertEqual(stranded.landing, .pending)
        XCTAssertTrue(try XCTUnwrap(stranded.landing).needsAttention)
        XCTAssertEqual(try f.tasks.awaitingLanding(projectId: f.project.id).map(\.id), [task.id])
    }

    func testNoBranchIsDistinctFromUnlandedAndAsksForNothing() throws {
        let f = try Fixture.make()
        let nonCode = try f.task("Write the release notes", column: .review)
        let stranded = try f.task("Ship the widget", column: .review)
        try f.board.accept(taskId: nonCode.id)
        try f.board.accept(taskId: stranded.id)

        try f.tasks.setLanding(nonCode.id, .noBranch, detail: nil)
        try f.tasks.setLanding(stranded.id, .unlanded, detail: "`agentboard/x` is not in `main`.")

        XCTAssertFalse(try XCTUnwrap(try f.tasks.get(nonCode.id)).needsLanding)
        XCTAssertTrue(try XCTUnwrap(try f.tasks.get(stranded.id)).needsLanding)
        XCTAssertEqual(try f.tasks.awaitingLanding(projectId: f.project.id).map(\.id), [stranded.id])
    }

    func testLeavingDoneClearsTheLanding() throws {
        let f = try Fixture.make()
        let task = try f.task("Ship the widget", column: .review)
        try f.board.accept(taskId: task.id)
        try f.tasks.setLanding(task.id, .unlanded, detail: "`agentboard/x` is not in `main`.")

        _ = try f.board.reopen(taskId: task.id)

        let reopened = try XCTUnwrap(try f.tasks.get(task.id))
        XCTAssertNil(reopened.landing)
        XCTAssertNil(reopened.landingDetail)
        XCTAssertEqual(try f.tasks.awaitingLanding(projectId: f.project.id), [])
    }

    /// Reordering inside `done` is not a new acceptance and must not throw away what git found.
    func testReorderingInsideDoneKeepsTheLanding() throws {
        let f = try Fixture.make()
        let first = try f.task("First", column: .review)
        let second = try f.task("Second", column: .review)
        try f.board.accept(taskId: first.id)
        try f.board.accept(taskId: second.id)
        try f.tasks.setLanding(first.id, .landed, detail: "`agentboard/x` is in `main`.")

        try f.tasks.move(first.id, to: .done, before: second.id)

        let moved = try XCTUnwrap(try f.tasks.get(first.id))
        XCTAssertEqual(moved.landing, .landed)
        XCTAssertEqual(moved.landingDetail, "`agentboard/x` is in `main`.")
    }

    /// A task already in `done` before the column existed claims nothing either way, so the board
    /// does not cry wolf over a backlog it cannot check.
    func testALandingRecordedBeforeTheColumnExistedClaimsNothing() throws {
        let f = try Fixture.make()
        let task = try f.task("Accepted long ago", column: .review)
        try f.board.accept(taskId: task.id)
        try f.db.writer.write { db in
            try db.execute(sql: "UPDATE task SET landing = NULL WHERE id = ?", arguments: [task.id])
        }

        let legacy = try XCTUnwrap(try f.tasks.get(task.id))
        XCTAssertNil(legacy.landing)
        XCTAssertFalse(legacy.needsLanding)
        XCTAssertEqual(try f.tasks.awaitingLanding(projectId: f.project.id), [])
    }

    func testEveryLandingSaysWhetherItNeedsAttention() {
        XCTAssertEqual(
            TaskLanding.allCases.filter(\.needsAttention),
            [.pending, .unlanded, .awaitingPullRequest, .pullRequestOpen],
            "a new landing must decide whether the board raises it"
        )
    }

    func testTheOpenPillNamesThePullRequestFromTheDetail() throws {
        let f = try Fixture.make()
        let task = try f.task("Shipped by pull request", column: .done)
        let pr = try XCTUnwrap(PullRequestReference(in: "opened\nhttps://github.com/acme/widgets/pull/16"))
        XCTAssertEqual(pr, PullRequestReference(url: "https://github.com/acme/widgets/pull/16", number: 16))
        try f.tasks.setLanding(task.id, .pullRequestOpen, detail: PullRequestLanding.openDetail(pr))
        XCTAssertEqual(try XCTUnwrap(try f.tasks.get(task.id)).landingLabel, "PR #16 open")
        XCTAssertEqual(
            PullRequestReference(in: PullRequestLanding.closedDetail(pr, branch: "agentboard/x")), pr,
            "the closed detail must still name the pull request, or the one-time adoption re-checks it forever"
        )
    }

    /// The default depends on the repository's `origin`, which decoding cannot see, so a project
    /// that never chose stores nothing.
    func testAStoredProjectWithoutTheSettingLeavesTheChoiceUnmade() {
        XCTAssertNil(ProjectSettings.decode("{}").standaloneIntegration)
        XCTAssertNil(ProjectSettings.forNewProject().standaloneIntegration)
        XCTAssertFalse(ProjectSettings().encoded().contains("standaloneIntegration"))
        var local = ProjectSettings()
        local.standaloneIntegration = .localMerge
        XCTAssertEqual(ProjectSettings.decode(local.encoded()).standaloneIntegration, .localMerge)
    }

    /// A pull request opened before `published_url` existed is known only by its progress row; the
    /// migration recovers it from that row and not from a newer one a worker wrote.
    func testTheBackfillRecoversAPullRequestFromThePublishRowAlone() throws {
        let f = try Fixture.make()
        let task = try f.task("Opened before the column", column: .review)
        let branch = "agentboard/\(task.id)"
        let approval = try f.board.requestPublish(
            projectId: f.project.id, kind: .pullRequest,
            request: PublishRequest(branch: branch, base: "main", title: task.title, body: ""),
            taskId: task.id, requestedBy: "orchestrator"
        )
        try f.approvals.resolve(approval.id, .approved)
        let url = "https://github.com/acme/widgets/pull/16"
        try f.board.recordPublished(approval: approval, summary: "Pull request opened from \(branch) into main.", url: url)
        try f.progress.append(
            taskId: task.id, sessionId: nil, kind: .status, text: "working: see https://github.com/upstream/lib/pull/9"
        )
        try f.db.writer.write { db in
            try db.execute(sql: "UPDATE approval SET published_url = NULL")
            try ApprovalStore.backfillPublishedURLs(db)
        }
        XCTAssertEqual(try f.tasks.recordedPullRequest(taskId: task.id)?.url, url)
    }
}
