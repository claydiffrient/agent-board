@testable import AgentBoardRuntime
import Darwin
import Foundation
import XCTest

final class WorktreeProcessStopTests: XCTestCase {
    /// SPEC §3.1: a terminal protects a process in the worktree unless an Agent Board host is its ancestor.
    func testATerminalProtectsOnlyWhatNoAgentBoardHostStarted() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let worktree = scratch.appendingPathComponent("worktree")
        let elsewhere = scratch.appendingPathComponent("elsewhere")
        for directory in [worktree, elsewhere] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: scratch) }

        let host = try withTerminal("exec /bin/sleep 600", cwd: worktree)
        defer { host.script.terminate() }
        let human = try withTerminal("cd '\(worktree.path)' && exec /bin/sleep 600", cwd: elsewhere)
        defer { human.script.terminate() }
        let hostIdentity = try XCTUnwrap(ProcessTable.current().identity(of: host.script.processIdentifier))

        let report = WorktreeProcessStopper.stop(in: worktree, agentHosts: [hostIdentity], grace: 2_000_000_000)

        XCTAssertTrue(report.stopped.contains { $0.pid == host.child }, "\(report)")
        XCTAssertEqual(report.kept.map(\.pid), [human.child], "\(report)")
        XCTAssertEqual(kill(human.child, 0), 0)
    }

    /// `script` gives its child a pty as controlling terminal, as a `claude --bg` pty host does.
    private func withTerminal(_ command: String, cwd: URL) throws -> (script: Process, child: pid_t) {
        let script = Process()
        script.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        script.arguments = ["-q", "/dev/null", "/bin/sh", "-c", command]
        script.currentDirectoryURL = cwd
        script.standardInput = FileHandle.nullDevice
        script.standardOutput = FileHandle.nullDevice
        script.standardError = FileHandle.nullDevice
        try script.run()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let table = ProcessTable.current()
            if let child = table.descendants(of: script.processIdentifier).first(where: {
                table.entries[$0]?.command == "sleep" && LibProc.facts($0)?.hasControllingTerminal == true
                    && LibProc.facts($0)?.cwd.map { $0.hasSuffix("/worktree") } == true
            }) {
                return (script, child)
            }
            usleep(50_000)
        }
        script.terminate()
        throw AgentRuntimeError("script did not start a child with a controlling terminal")
    }
}
