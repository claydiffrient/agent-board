import AgentBoardCore
import AgentBoardRuntime
import Foundation
import XCTest
@testable import AgentBoard

/// SPEC §9: a pin on a session with no conversation must not be resumed, or every Restart exits
/// with "No conversation found with session ID".
@MainActor
final class ConsoleSessionResumeTests: XCTestCase {
    func testAPinWhoseTranscriptHoldsOnlyMetadataFallsBackToTheLatestRealConversation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("console-resume-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let projectsRoot = root.appendingPathComponent("claude-projects")
        let db = try AppDatabase.inMemory()
        let project = try ProjectStore(db).register(
            name: "Resume", repoPath: root.appendingPathComponent("repo").path, baseBranch: "main",
            worktreeRoot: root.appendingPathComponent("worktrees").path, memoryDir: nil
        )
        let sessions = SessionStore(db)
        for id in ["b3cdfce8", "be9c05ef"] {
            try sessions.insert(AgentSession(
                sessionId: id, projectId: project.id, role: .orchestrator, cwd: project.repoPath, state: .stopped
            ))
        }
        try transcript("b3cdfce8", in: project, projectsRoot: projectsRoot, lines: [
            #"{"type":"user","message":{"role":"user","content":"hi"}}"#,
            #"{"type":"continued-in","continuedInSessionId":"be9c05ef"}"#,
        ])
        try transcript("be9c05ef", in: project, projectsRoot: projectsRoot, lines: [
            #"{"type":"ai-title","aiTitle":"Side session"}"#,
            #"{"type":"agent-name","agentName":"orchestrator"}"#,
        ])
        try ProjectStore(db).setOrchestratorSession(project.id, sessionId: "be9c05ef")

        let source = ProjectOrchestratorSource(
            projectId: project.id, db: db, sessionConfigDir: root.appendingPathComponent("config"),
            projectsRoot: projectsRoot, claude: ClaudeInvocation(executable: "/usr/bin/true")
        )

        XCTAssertEqual(try source.resolveSession(port: 1), "b3cdfce8")
        XCTAssertEqual(try ProjectStore(db).get(project.id)?.orchSessionId, "b3cdfce8")
    }

    private func transcript(_ sessionId: String, in project: Project, projectsRoot: URL, lines: [String]) throws {
        let url = ClaudeProjectPaths.transcriptURL(forCwd: project.repoPath, sessionId: sessionId, projectsRoot: projectsRoot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
