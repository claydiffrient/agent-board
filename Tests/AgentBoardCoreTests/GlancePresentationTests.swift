import Foundation
import XCTest
@testable import AgentBoardCore

private func makeProject(_ name: String, workspaceId: String? = nil) -> Project {
    Project(
        id: "p-\(name)", name: name, repoPath: "/tmp/\(name)", baseBranch: "main",
        worktreeRoot: "/tmp/\(name)-worktrees", memoryDir: nil, orchSessionId: nil,
        settingsJSON: "{}", createdAt: 0, workspaceId: workspaceId
    )
}

private func makeWorkspace(_ id: String, _ name: String, _ ordering: Double) -> Workspace {
    Workspace(id: id, name: name, ordering: ordering, createdAt: 0)
}

private func glance(_ name: String, running: Int = 0, review: Int = 0, ready: Int = 0) -> ProjectGlance {
    ProjectGlance(id: "p-\(name)", name: name, running: running, review: review, ready: ready)
}

final class GlanceHeadlineTests: XCTestCase {
    func testAnEmptyBoardReadsAsReassuranceNotAsZeroes() {
        let text = GlanceHeadline.text(workingSessions: 0, tasksInReview: 0)
        XCTAssertEqual(text, "Nothing running, and nothing is waiting on you.")
        XCTAssertFalse(text.contains("0"), "zero must never be rendered as a digit in the headline")
    }

    func testOneOfEachIsSingular() {
        XCTAssertEqual(
            GlanceHeadline.text(workingSessions: 1, tasksInReview: 1),
            "1 agent working, 1 task awaiting your review."
        )
    }

    func testSeveralOfEachIsPlural() {
        XCTAssertEqual(
            GlanceHeadline.text(workingSessions: 4, tasksInReview: 3),
            "4 agents working, 3 tasks awaiting your review."
        )
    }

    func testEitherHalfCanBeZeroWithoutADigit() {
        XCTAssertEqual(
            GlanceHeadline.text(workingSessions: 0, tasksInReview: 2),
            "Nothing running, 2 tasks awaiting your review."
        )
        XCTAssertEqual(
            GlanceHeadline.text(workingSessions: 2, tasksInReview: 0),
            "2 agents working, nothing awaiting your review."
        )
    }
}

final class ProjectGlanceIdleTests: XCTestCase {
    func testAllZeroesIsIdle() {
        XCTAssertTrue(glance("quiet").isIdle)
    }

    func testAnyNonZeroColumnIsNotIdle() {
        XCTAssertFalse(glance("a", running: 1).isIdle)
        XCTAssertFalse(glance("b", review: 1).isIdle)
        XCTAssertFalse(glance("c", ready: 1).isIdle)
    }
}

final class GlanceGroupingTests: XCTestCase {
    func testCardsSitInTheSameSectionsAndOrderAsTheSidebar() {
        let personal = makeWorkspace("w-personal", "Personal", 1)
        let work = makeWorkspace("w-work", "Work", 2)
        let projects = [
            makeProject("derivita-ui", workspaceId: work.id),
            makeProject("agent-board", workspaceId: personal.id),
            makeProject("loose"),
        ]
        let workspaces = [work, personal]
        let summary = GlanceSummary(
            projects: [glance("agent-board", running: 2), glance("derivita-ui", review: 1), glance("loose")],
            workingSessions: 2, tasksInReview: 1
        )

        let sections = GlanceGrouping.sections(projects: projects, workspaces: workspaces, summary: summary)
        let sidebar = ProjectGrouping.sections(projects: projects, workspaces: workspaces)

        XCTAssertEqual(sections.map(\.id), sidebar.map(\.id))
        XCTAssertEqual(sections.map { $0.cards.map(\.id) }, sidebar.map { $0.projects.map(\.id) })
        XCTAssertEqual(sections.map(\.title), ["Personal", "Work", "Ungrouped"])
    }

    func testAProjectInNoWorkspaceLandsInUngrouped() {
        let work = makeWorkspace("w-work", "Work", 1)
        let sections = GlanceGrouping.sections(
            projects: [makeProject("loose"), makeProject("owned", workspaceId: work.id)],
            workspaces: [work],
            summary: GlanceSummary(projects: [glance("loose"), glance("owned")], workingSessions: 0, tasksInReview: 0)
        )

        XCTAssertEqual(sections.last?.id, ProjectSection.ungroupedId)
        XCTAssertEqual(sections.last?.title, "Ungrouped")
        XCTAssertEqual(sections.last?.cards.map(\.name), ["loose"])
    }

    func testWithNoWorkspacesTheSingleSectionIsUntitledLikeTheSidebar() {
        let sections = GlanceGrouping.sections(
            projects: [makeProject("solo")],
            workspaces: [],
            summary: GlanceSummary(projects: [glance("solo", ready: 3)], workingSessions: 0, tasksInReview: 0)
        )

        XCTAssertEqual(sections.count, 1)
        XCTAssertNil(sections[0].title)
        XCTAssertEqual(sections[0].cards.map(\.ready), [3])
    }

    func testEveryProjectGetsACardIncludingOnesWithNothingHappening() {
        let sections = GlanceGrouping.sections(
            projects: [makeProject("busy"), makeProject("quiet")],
            workspaces: [],
            summary: GlanceSummary(
                projects: [glance("busy", running: 1), glance("quiet")], workingSessions: 1, tasksInReview: 0
            )
        )

        XCTAssertEqual(sections[0].cards.map(\.name), ["busy", "quiet"])
        XCTAssertTrue(try XCTUnwrap(sections[0].cards.last).isIdle)
    }

    /// The project list and the summary are two observations that can land a frame apart; a project
    /// the counts have not caught up with must still get a card rather than vanish.
    func testAProjectMissingFromTheSummaryStillGetsAnIdleCard() {
        let sections = GlanceGrouping.sections(
            projects: [makeProject("brand-new")],
            workspaces: [],
            summary: .empty
        )

        XCTAssertEqual(sections[0].cards.map(\.name), ["brand-new"])
        XCTAssertTrue(try XCTUnwrap(sections[0].cards.first).isIdle)
    }
}
