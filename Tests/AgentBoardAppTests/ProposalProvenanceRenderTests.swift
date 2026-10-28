import AgentBoardCore
import AppKit
import SwiftUI
import Vision
import XCTest
@testable import AgentBoard

/// SPEC §10: a Walk me through it proposal names its pull request on its card and in its detail,
/// read back from the proposal report the verifier wrote.
@MainActor
final class ProposalProvenanceRenderTests: XCTestCase {
    private var db: AppDatabase!
    private var project: Project!

    override func setUp() async throws {
        db = try AppDatabase.inMemory()
        project = try ProjectStore(db).register(
            name: "Demo", repoPath: "/tmp/demo-\(UUID().uuidString)", baseBranch: "main",
            worktreeRoot: "/tmp/demo-worktrees", memoryDir: nil
        )
    }

    func testAVerifyProposalNamesItsPullRequestAndAWorkerProposalDoesNot() async throws {
        let board = Board(db)
        let verified = try board.propose(
            projectId: project.id, title: "Empty state card", body: nil, rationale: nil, sessionId: nil,
            epicId: nil, origin: .verifySession,
            source: ProposalProvenance.reportLine(pullRequest: "example-org/app#42")
        )
        let worker = try board.propose(
            projectId: project.id, title: "Lint cleanup", body: nil, rationale: nil, sessionId: nil, epicId: nil
        )
        let observed = try await ProposalProvenance.observePullRequests(projectId: project.id)
            .values(in: db.reader).first { _ in true }
        let pullRequests = try XCTUnwrap(observed)

        let cards = VStack(spacing: 24) {
            ForEach([verified, worker]) { task in
                TaskCardView(
                    task: task, epicTitle: nil, activeSession: nil, latestSession: nil, isSelected: false,
                    verifyPullRequest: pullRequests[task.id], onAccept: {}, onReopen: {}
                )
            }
        }
        .padding()
        .frame(width: 320)
        let cardText = try ocr(cards, size: CGSize(width: 320, height: 240))
        let verifiedCard = try text(between: "Empty state card", and: "Lint cleanup", in: cardText)
        XCTAssertTrue(verifiedCard.contains("Walk me through it"), "verify card read as: \(verifiedCard)")
        XCTAssertTrue(verifiedCard.contains("example-org/app#42"), "verify card read as: \(verifiedCard)")
        let workerCard = try text(between: "Lint cleanup", and: nil, in: cardText)
        XCTAssertFalse(workerCard.contains("Walk me through"), "worker card read as: \(workerCard)")

        let inspector = TaskInspectorView(
            task: verified, allTasks: [verified], sessions: [], drafts: TaskDraftCache(),
            verifyPullRequest: pullRequests[verified.id], onClose: {}
        )
        let detail = try ocr(inspector, size: CGSize(width: 420, height: 600)).joined(separator: " | ")
        XCTAssertTrue(detail.contains("Walk me through it"), "detail read as: \(detail)")
        XCTAssertTrue(detail.contains("example-org/app#42"), "detail read as: \(detail)")
    }

    /// Recognized lines top to bottom. SwiftUI `Text` leaves no string in the AppKit view tree.
    private func ocr(_ view: some View, size: CGSize) throws -> [String] {
        let mount = OffscreenMount(view.environment(renderEnvironment(db: db)), size: size)
        defer { mount.close() }
        _ = try mount.capture()
        let image = try XCTUnwrap(CGWindowListCreateImage(
            .null, .optionIncludingWindow, CGWindowID(mount.window.windowNumber),
            [.boundsIgnoreFraming, .bestResolution]
        ))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? [])
            .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
            .compactMap { $0.topCandidates(1).first?.string }
    }

    private func text(between start: String, and end: String?, in lines: [String]) throws -> String {
        let from = try XCTUnwrap(lines.firstIndex { $0.contains(start) }, "\"\(start)\" not found in: \(lines)")
        let to = end.flatMap { end in lines.firstIndex { $0.contains(end) } } ?? lines.endIndex
        return lines[from..<max(from, to)].joined(separator: " | ")
    }
}
