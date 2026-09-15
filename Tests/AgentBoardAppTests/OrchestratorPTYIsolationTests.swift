import XCTest
@testable import AgentBoard

/// D9 / SPEC §9.1: nothing but Agent Board's own fixed lines is written into the orchestrator PTY.
/// There is no display here to watch a real terminal with, so the invariant is asserted against the
/// source tree — which fails the moment anything else acquires a write, which is the breach.
final class OrchestratorPTYIsolationTests: XCTestCase {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // AgentBoardAppTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()
    }

    private func swiftSources() throws -> [URL] {
        let sources = Self.repoRoot.appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    func testOnlyTheOrchestratorConsoleWritesIntoThePTY() throws {
        var writers: Set<String> = []
        for url in try swiftSources() where (try String(contentsOf: url, encoding: .utf8)).contains(".send(txt:") {
            writers.insert(url.lastPathComponent)
        }
        XCTAssertEqual(writers, ["OrchestratorConsole.swift"])
    }

    /// Every write is either one of the three fixed lines or the terminator that submits it. A
    /// fourth would have to be added here deliberately.
    func testEveryWriteIsAFixedAppAuthoredLine() throws {
        let console = try String(
            contentsOf: Self.repoRoot
                .appendingPathComponent("Sources/AgentBoard/Services/OrchestratorConsole.swift"),
            encoding: .utf8
        )
        let writes = console
            .split(separator: "\n")
            .filter { $0.contains(".send(txt:") }
            .map { $0.trimmingCharacters(in: .whitespaces) }

        XCTAssertEqual(writes, [
            #"terminal.send(txt: line)"#,
            #"terminal.send(txt: "\r")"#,
        ], "a write bypassed inject(_:), which is what keeps the terminator a separate burst")

        for constant in ["OrchestratorCompaction.command", "OrchestratorCompaction.reorientation"] {
            XCTAssertTrue(console.contains("inject(\(constant))"), "\(constant) is not what gets injected")
        }
        XCTAssertTrue(console.contains(#"inject("[agent-board] \(count) reports pending. Call list_reports.")"#))
    }
}
