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

final class ProjectGroupingTests: XCTestCase {
    func testGroupsProjectsUnderTheirWorkspaceInOrderingOrder() {
        let personal = makeWorkspace("w-personal", "Personal", 1)
        let work = makeWorkspace("w-work", "Work", 2)
        let sections = ProjectGrouping.sections(
            projects: [
                makeProject("derivita-ui", workspaceId: work.id),
                makeProject("agent-board", workspaceId: personal.id),
                makeProject("Derivita", workspaceId: work.id),
                makeProject("clayd.dev", workspaceId: personal.id),
            ],
            workspaces: [work, personal]
        )

        XCTAssertEqual(sections.map(\.workspace?.name), ["Personal", "Work"])
        XCTAssertEqual(sections[0].projects.map(\.name), ["agent-board", "clayd.dev"])
        XCTAssertEqual(sections[1].projects.map(\.name), ["derivita-ui", "Derivita"])
    }

    func testUngroupedProjectsComeLast() {
        let personal = makeWorkspace("w-personal", "Personal", 1)
        let sections = ProjectGrouping.sections(
            projects: [makeProject("loose"), makeProject("agent-board", workspaceId: personal.id)],
            workspaces: [personal]
        )

        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections.last?.workspace, nil)
        XCTAssertTrue(sections.last?.isUngrouped == true)
        XCTAssertEqual(sections.last?.id, ProjectSection.ungroupedId)
        XCTAssertEqual(sections.last?.projects.map(\.name), ["loose"])
    }

    func testEmptyWorkspaceIsStillShown() {
        let empty = makeWorkspace("w-empty", "Empty", 1)
        let full = makeWorkspace("w-full", "Full", 2)
        let sections = ProjectGrouping.sections(
            projects: [makeProject("agent-board", workspaceId: full.id)],
            workspaces: [empty, full]
        )

        XCTAssertEqual(sections.map(\.workspace?.name), ["Empty", "Full"])
        XCTAssertEqual(sections[0].projects, [])
    }

    func testEmptyUngroupedSectionIsOmitted() {
        let personal = makeWorkspace("w-personal", "Personal", 1)
        let sections = ProjectGrouping.sections(
            projects: [makeProject("agent-board", workspaceId: personal.id)],
            workspaces: [personal]
        )

        XCTAssertEqual(sections.count, 1)
        XCTAssertFalse(sections.contains { $0.isUngrouped })
    }

    func testNoWorkspacesAtAllProducesOneUngroupedSection() {
        let sections = ProjectGrouping.sections(
            projects: [makeProject("a"), makeProject("b")],
            workspaces: []
        )

        XCTAssertEqual(sections.count, 1)
        XCTAssertTrue(sections[0].isUngrouped)
        XCTAssertEqual(sections[0].projects.map(\.name), ["a", "b"])
    }

    func testNothingAtAllProducesNoSections() {
        XCTAssertEqual(ProjectGrouping.sections(projects: [], workspaces: []), [])
    }

    func testDanglingWorkspaceIdFallsBackToUngrouped() {
        let personal = makeWorkspace("w-personal", "Personal", 1)
        let sections = ProjectGrouping.sections(
            projects: [
                makeProject("orphan", workspaceId: "w-deleted"),
                makeProject("agent-board", workspaceId: personal.id),
            ],
            workspaces: [personal]
        )

        XCTAssertEqual(sections.map(\.id), [personal.id, ProjectSection.ungroupedId])
        XCTAssertEqual(sections.last?.projects.map(\.name), ["orphan"])
    }

    func testWorkspacesWithEqualOrderingFallBackToNameThenId() {
        let sections = ProjectGrouping.sections(
            projects: [],
            workspaces: [
                makeWorkspace("w-b", "beta", 1),
                makeWorkspace("w-a", "Alpha", 1),
                makeWorkspace("w-z", "Alpha", 1),
            ]
        )

        XCTAssertEqual(sections.map(\.workspace?.id), ["w-a", "w-z", "w-b"])
    }
}
