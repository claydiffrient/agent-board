import AgentBoardBridge
import AgentBoardCore
import AgentBoardServer
import Foundation
import XCTest

final class PublishToolTests: XCTestCase {
    private var f: BridgeFixture!

    override func setUpWithError() throws {
        f = try BridgeFixture.make()
        // Autonomy on everywhere below: publishing must still wait on a human.
        try f.setAutonomy(true)
    }

    private func pending(_ kind: ApprovalKind) throws -> [Approval] {
        try f.approvals.pending(projectId: f.project.id).filter { $0.kind == kind }
    }

    // MARK: push_branch

    func testPushBranchCreatesAPendingApprovalAndPushesNothing() async throws {
        let task = try f.task("t")
        let result = try await f.call("push_branch", ["branch": .string("agentboard/\(task.id)")])

        let approvals = try pending(.push)
        XCTAssertEqual(approvals.count, 1)
        let approval = try XCTUnwrap(approvals.first)
        XCTAssertEqual(try approval.publishRequest().branch, "agentboard/\(task.id)")
        XCTAssertEqual(approval.taskId, task.id)
        XCTAssertTrue(result.text.contains(approval.id), result.text)
        XCTAssertTrue(result.text.contains("pending"), result.text)
    }

    func testPushBranchAcceptsTheProjectsBaseBranch() async throws {
        _ = try await f.call("push_branch", ["branch": .string("main")])
        let approval = try XCTUnwrap(try pending(.push).first)
        XCTAssertEqual(try approval.publishRequest().branch, "main")
        XCTAssertNil(approval.taskId)
        XCTAssertNil(approval.epicId)
    }

    func testPushBranchRefusesAnyBranchTheProjectDoesNotOwn() async throws {
        for branch in ["develop", "origin/main", "refs/heads/main", "release/2.0", "agentboard"] {
            await XCTAssertToolError(
                try await f.call("push_branch", ["branch": .string(branch)]),
                containing: "only push branches it owns"
            )
        }
        XCTAssertTrue(try pending(.push).isEmpty)
    }

    func testPushBranchRefusesRefspecsOptionsAndJunk() async throws {
        for branch in [":", "agentboard/a:refs/heads/main", "--delete", "agentboard/a b", "agentboard/a..b", ""] {
            await XCTAssertToolError(try await f.call("push_branch", ["branch": .string(branch)]))
        }
        XCTAssertTrue(try pending(.push).isEmpty)
    }

    func testASecondRequestForTheSameBranchReusesTheSameApproval() async throws {
        let task = try f.task("t")
        _ = try await f.call("push_branch", ["branch": .string("agentboard/\(task.id)")])
        _ = try await f.call("push_branch", ["branch": .string("agentboard/\(task.id)")])
        XCTAssertEqual(try pending(.push).count, 1)
    }

    // MARK: open_pull_request

    func testOpenPullRequestOnAnEpicUsesTheEpicBranchAndTheProjectBase() async throws {
        let epic = try f.epic("Ship it")
        _ = try f.task("t", column: .done, epicId: epic.id)
        let result = try await f.call("open_pull_request", [
            "epic_id": .string(epic.id),
            "title": .string("Ship it"),
            "body": .string("The epic's work."),
        ])

        let approval = try XCTUnwrap(try pending(.pullRequest).first)
        let request = try approval.publishRequest()
        XCTAssertEqual(request.branch, epic.branch)
        XCTAssertEqual(request.base, "main")
        XCTAssertEqual(request.title, "Ship it")
        XCTAssertEqual(request.body, "The epic's work.")
        XCTAssertEqual(approval.epicId, epic.id)
        XCTAssertTrue(result.text.contains(approval.id), result.text)
        XCTAssertTrue(result.text.contains("no pull request"), result.text)
    }

    func testAnEpicWithUnfinishedTasksIsAllowedAndTheApprovalSaysSo() async throws {
        let epic = try f.epic("Half done")
        _ = try f.task("done one", column: .done, epicId: epic.id)
        _ = try f.task("still running", column: .running, epicId: epic.id)

        _ = try await f.call("open_pull_request", ["epic_id": .string(epic.id), "title": .string("Early review")])
        let approval = try XCTUnwrap(try pending(.pullRequest).first)
        let reason = try XCTUnwrap(approval.reason)
        XCTAssertTrue(reason.contains("not ready for integration"), reason)
        XCTAssertTrue(reason.contains("1 of 2"), reason)
    }

    func testAReadyEpicsApprovalDoesNotCarryAnUnfinishedWarning() async throws {
        let epic = try f.epic("All done")
        _ = try f.task("t", column: .done, epicId: epic.id)
        _ = try await f.call("open_pull_request", ["epic_id": .string(epic.id), "title": .string("Ready")])
        let reason = try XCTUnwrap(try pending(.pullRequest).first?.reason)
        XCTAssertFalse(reason.contains("not ready"), reason)
    }

    func testOpenPullRequestTakesABranchDirectlyAndAnExplicitBase() async throws {
        let task = try f.task("t")
        _ = try await f.call("open_pull_request", [
            "branch": .string("agentboard/\(task.id)"),
            "title": .string("One task"),
            "base": .string("main"),
        ])
        let approval = try XCTUnwrap(try pending(.pullRequest).first)
        XCTAssertEqual(try approval.publishRequest().branch, "agentboard/\(task.id)")
        XCTAssertEqual(try approval.publishRequest().base, "main")
        XCTAssertEqual(approval.taskId, task.id)
    }

    func testOpenPullRequestRefusesABranchTheProjectDoesNotOwn() async throws {
        await XCTAssertToolError(
            try await f.call("open_pull_request", ["branch": .string("develop"), "title": .string("No")]),
            containing: "only push branches it owns"
        )
        await XCTAssertToolError(
            try await f.call("open_pull_request", [
                "branch": .string("agentboard/x"), "title": .string("No"), "base": .string("someone-elses-branch"),
            ]),
            containing: "only push branches it owns"
        )
        XCTAssertTrue(try pending(.pullRequest).isEmpty)
    }

    func testOpenPullRequestNeedsSomethingToOpenFrom() async throws {
        await XCTAssertToolError(
            try await f.call("open_pull_request", ["title": .string("From what?")]),
            containing: "Name either epic_id or branch"
        )
    }

    func testOpenPullRequestRefusesAnEpicFromAnotherProject() async throws {
        let other = try f.otherProject()
        let epic = try f.epic("Theirs", in: other.id)
        await XCTAssertToolError(
            try await f.call("open_pull_request", ["epic_id": .string(epic.id), "title": .string("No")]),
            containing: "not in this project"
        )
    }

    func testOpenPullRequestRefusesMergingABranchIntoItself() async throws {
        await XCTAssertToolError(
            try await f.call("open_pull_request", [
                "branch": .string("main"), "title": .string("No"), "base": .string("main"),
            ]),
            containing: "into itself"
        )
    }

    // MARK: Scope and descriptions

    func testBothToolsAreOnTheOrchestratorSurfaceOnly() async throws {
        let orchestratorTools = Set(await f.orchestrator.tools(for: f.orchestratorIdentity).map(\.name))
        XCTAssertTrue(orchestratorTools.contains("push_branch"))
        XCTAssertTrue(orchestratorTools.contains("open_pull_request"))

        let task = try f.task("t", column: .running)
        try f.session("w1", taskId: task.id)
        let worker = f.workerIdentity(sessionId: "w1", taskId: task.id)
        let workerTools = Set(await f.scoped.tools(for: worker).map(\.name))
        XCTAssertFalse(workerTools.contains("push_branch"))
        XCTAssertFalse(workerTools.contains("open_pull_request"))

        await XCTAssertToolError(try await f.call("push_branch", ["branch": .string("agentboard/\(task.id)")], as: worker))
        await XCTAssertToolError(
            try await f.call(
                "open_pull_request", ["branch": .string("agentboard/\(task.id)"), "title": .string("No")], as: worker
            )
        )
    }

    func testTheDescriptionsSayTheApprovalIsUnconditional() async throws {
        let descriptors = await f.orchestrator.tools(for: f.orchestratorIdentity)
        for name in ["push_branch", "open_pull_request"] {
            let description = try XCTUnwrap(descriptors.first { $0.name == name }?.description)
            XCTAssertTrue(description.contains("regardless of the autonomy setting"), name)
            XCTAssertTrue(description.contains("pending approval"), name)
        }
    }
}
