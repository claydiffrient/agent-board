import XCTest
@testable import AgentBoardRuntime

final class HumanShellEnvironmentTests: XCTestCase {
    private func value(_ key: String, in lines: [String]) -> String? {
        lines.first { $0.hasPrefix("\(key)=") }.map { String($0.dropFirst(key.count + 1)) }
    }

    func testEveryBoardAuthorityVariableIsDroppedByName() {
        let token = "8f3a1c0d94b27e651af0c3d2b7e94a10"
        let base = Dictionary(uniqueKeysWithValues: ChildEnvironment.boardAuthorityVariables.map { ($0, token) })
            .merging(["PATH": "/usr/bin:/bin"]) { _, new in new }

        let lines = ChildEnvironment.forHumanShell(base)

        for name in ChildEnvironment.boardAuthorityVariables {
            XCTAssertNil(value(name, in: lines), "\(name) reached the human shell")
        }
        XCTAssertFalse(lines.contains { $0.contains(token) })
        XCTAssertEqual(value("PATH", in: lines), "/usr/bin:/bin")
    }

    func testTheHumanShellStillGetsTheTerminalDefaults() {
        let lines = ChildEnvironment.forHumanShell(["PATH": "/bin", "FORCE_COLOR": "3"])
        XCTAssertEqual(value("TERM", in: lines), "xterm-256color")
        XCTAssertEqual(value("COLORTERM", in: lines), "truecolor")
        XCTAssertEqual(value("LANG", in: lines), "en_US.UTF-8")
    }

    func testTheShellComesFromSHELL() {
        XCTAssertEqual(LoginShell.path(["SHELL": "/opt/homebrew/bin/fish"]), "/opt/homebrew/bin/fish")
    }

    func testAMissingOrRelativeSHELLFallsBackToZsh() {
        XCTAssertEqual(LoginShell.path([:]), "/bin/zsh")
        XCTAssertEqual(LoginShell.path(["SHELL": ""]), "/bin/zsh")
        XCTAssertEqual(LoginShell.path(["SHELL": "fish"]), "/bin/zsh")
    }

    func testArgv0IsDashedSoTheProfileIsSourced() {
        XCTAssertEqual(LoginShell.argv0(forPath: "/bin/zsh"), "-zsh")
        XCTAssertEqual(LoginShell.argv0(forPath: "/opt/homebrew/bin/fish"), "-fish")
    }
}
