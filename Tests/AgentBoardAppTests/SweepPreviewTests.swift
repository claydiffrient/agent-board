import AgentBoardCore
import AgentBoardRuntime
import AppKit
import SwiftUI
import XCTest
@testable import AgentBoard

/// The Preview Leaked-Agent Sweep window (SPEC §8.6, §10). The report sits in an `NSTextView`, whose
/// `string` is readable offscreen where a SwiftUI `Text` is not, so these read the lines themselves.
/// Nobody has looked at the window's pixels: layout, wrapping and the monospaced font are unverified.
@MainActor
final class SweepPreviewTests: XCTestCase {
    private var fixture: SupervisorFixture!

    override func setUp() async throws {
        fixture = try SupervisorFixture.make()
        for (shortId, state) in [("leaked", SessionState.completed), ("busy", .running)] {
            try fixture.sessions.insert(AgentSession(
                sessionId: "session-\(shortId)", shortId: shortId, projectId: fixture.project.id,
                role: .worker, cwd: fixture.supportDir.path, state: state
            ))
        }
        try fixture.sessions.insert(AgentSession(
            sessionId: "session-unpromoted", projectId: fixture.project.id, role: .worker,
            cwd: fixture.supportDir.path, state: .completed
        ))
        await fixture.runtime.setListed([
            AgentInfo(id: "leaked", cwd: "/tmp", kind: "background", sessionId: "uuid-leaked", state: "done", pid: 9001),
            AgentInfo(id: "busy", cwd: "/tmp", kind: "background", sessionId: "uuid-busy", state: "working", pid: 9002),
        ])
    }

    override func tearDown() async throws {
        await fixture.cleanUp()
        fixture = nil
    }

    /// Control: a supervisor with nothing to sweep puts no decision line in the text view, so a
    /// `KEPT` line below comes from the report rather than from the mount.
    func testWithNoSupervisorTheWindowSaysSoAndListsNoDecisions() throws {
        let mount = OffscreenMount(SweepPreviewWindow(preview: SweepPreview(supervisor: StubSupervisor())))
        defer { mount.close() }

        let text = settle(mount.host) { !$0.isEmpty && !$0.hasPrefix("Running") }

        XCTAssertEqual(text, "This build has no supervisor to ask, so there is nothing to preview.")
    }

    func testTheWindowShowsEveryKeepWithItsReason() throws {
        let mount = OffscreenMount(SweepPreviewWindow(preview: SweepPreview(supervisor: fixture.supervisor)))
        defer { mount.close() }

        let text = settle(mount.host) { $0.contains("UNTRACKED") }

        XCTAssertTrue(text.contains("KEPT busy session-busy — state running is active"), text)
        XCTAssertTrue(
            text.contains("KEPT - session-unpromoted — no short id: the board never learned of an agent for this row"),
            text
        )
        XCTAssertTrue(
            text.contains("WOULD-STOP leaked session-leaked — state completed is inactive but the agent was never stopped"),
            text
        )
    }

    /// The preview must neither stop the leak nor record it as stopped, or the launch sweep would
    /// then skip it.
    func testThePreviewStopsNothingAndLeavesTheLaunchSweepItsTarget() async throws {
        let preview = SweepPreview(supervisor: fixture.supervisor)

        await preview.run()

        guard case let .finished(report) = preview.state else { return XCTFail("\(preview.state)") }
        XCTAssertTrue(report.dryRun)
        XCTAssertEqual(report.wouldStop.map(\.shortId), ["leaked"])
        let afterPreview = await fixture.runtime.stopped
        XCTAssertEqual(afterPreview, [], "the preview stopped a session")

        _ = await fixture.supervisor.sweepLeakedAgents()
        let afterLaunch = await fixture.runtime.stopped
        XCTAssertEqual(afterLaunch, ["leaked"], "the preview recorded the leak as already stopped")
    }

    private func settle(_ host: NSView, until done: (String) -> Bool) -> String {
        let deadline = Date().addingTimeInterval(10)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        } while !done(reportText(in: host)) && Date() < deadline
        return reportText(in: host)
    }

    private func reportText(in view: NSView) -> String {
        if let text = view as? NSTextView { return text.string }
        for subview in view.subviews {
            let found = reportText(in: subview)
            if !found.isEmpty { return found }
        }
        return ""
    }
}
