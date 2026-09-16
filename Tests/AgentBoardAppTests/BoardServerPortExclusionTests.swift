import AgentBoardRuntime
import AgentBoardServer
import Foundation
import XCTest

/// `BoardServer` binds an ephemeral port whenever its preferred one is taken, so the exclusion has
/// to read the bound port off the running server rather than assume a constant.
final class BoardServerPortExclusionTests: XCTestCase {
    private var server: BoardServer!
    private var boundPort = 0

    override func setUp() async throws {
        server = BoardServer(tokens: NoTokens(), hooks: NoHooks(), tools: NoTools())
        boundPort = try await server.start()
    }

    override func tearDown() async throws {
        await server.stop()
        server = nil
    }

    func testTheBoardsOwnPortIsAbsentFromASweepTakenWhileItIsBound() async throws {
        let reported = await server.port
        let port = try XCTUnwrap(reported)
        XCTAssertEqual(port, boundPort)

        let swept = ListeningPortSweep.sweep(sessionPIDs: [:], boardServerPort: port)

        XCTAssertFalse(swept.contains { $0.port == port }, "the board's own port reached the sweep")
    }

    /// Without the exclusion the same sweep does find the port, so the assertion above is not
    /// passing because the sweep cannot see this process at all.
    func testTheSameSweepFindsThatPortWhenNothingIsExcluded() async throws {
        let reported = await server.port
        let port = try XCTUnwrap(reported)

        let swept = ListeningPortSweep.sweep(sessionPIDs: [:], boardServerPort: nil)

        let row = try XCTUnwrap(swept.first { $0.port == port })
        XCTAssertEqual(row.pid, ProcessInfo.processInfo.processIdentifier)
    }
}

private struct NoTokens: TokenResolver {
    func resolve(token: String) async -> TokenIdentity? { nil }
}

private struct NoHooks: HookSink {
    func handle(_ event: HookEvent, identity: TokenIdentity) async -> HookDecision? { nil }
}

private struct NoTools: ToolHandler {
    func tools(for identity: TokenIdentity) async -> [ToolDescriptor] { [] }
    func call(_ name: String, arguments: JSONValue, identity: TokenIdentity) async throws -> ToolResult {
        ToolResult(text: "")
    }
}
