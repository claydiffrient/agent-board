import Foundation
import XCTest
@testable import AgentBoardCore

final class VerificationCommandsTests: XCTestCase {
    /// The exact shape `ProjectSettings.encoded()` produced before build/test commands existed.
    /// Every project on disk has a row like this one.
    private let settingsJSONBeforeVerificationCommands = """
    {"archivePolicy":{"mode":"afterEpicMerge"},"autoModeJSON":"{\\"soft_deny\\":[\\"$defaults\\"]}",\
    "autonomyEnabled":true,"caps":{"maxConcurrentWorkers":2,"maxIdleSeconds":300,\
    "maxWallClockSeconds":1800,"shutdownGraceSeconds":120,"stallSeconds":120},\
    "defaultModel":"claude-opus-5","extraMcpServers":["mdn"],"modelGuidance":"Sonnet for docs"}
    """

    func testSettingsRowWrittenBeforeThisChangeStillDecodes() throws {
        let settings = ProjectSettings.decode(settingsJSONBeforeVerificationCommands)

        XCTAssertNil(settings.buildCommand)
        XCTAssertNil(settings.testCommand)
        XCTAssertTrue(settings.verification.isEmpty)
        XCTAssertEqual(settings.notifications, NotificationPreferences())
        for category in NotificationCategory.allCases {
            XCTAssertTrue(settings.notifications.isEnabled(category), category.rawValue)
        }
        XCTAssertEqual(settings.notifications.mute, NotificationMute.none)
        XCTAssertEqual(settings.caps.maxConcurrentWorkers, 2)
        XCTAssertEqual(settings.defaultModel, "claude-opus-5")
        XCTAssertEqual(settings.modelGuidance, "Sonnet for docs")
        XCTAssertEqual(settings.extraMcpServers, ["mdn"])
        XCTAssertEqual(settings.archivePolicy, .afterEpicMerge)
        XCTAssertTrue(settings.autonomyEnabled)
    }

    func testCommandsDefaultToEmptyAndRoundTrip() {
        XCTAssertNil(ProjectSettings().buildCommand)
        XCTAssertNil(ProjectSettings().testCommand)

        var settings = ProjectSettings()
        settings.buildCommand = "pnpm build"
        settings.testCommand = "pnpm test"
        let decoded = ProjectSettings.decode(settings.encoded())

        XCTAssertEqual(decoded.buildCommand, "pnpm build")
        XCTAssertEqual(decoded.testCommand, "pnpm test")
        XCTAssertEqual(decoded.verification, VerificationCommands(build: "pnpm build", test: "pnpm test"))
    }

    func testBlankAndWhitespaceCommandsNormalizeToNil() {
        XCTAssertTrue(VerificationCommands(build: "", test: "  \n ").isEmpty)
        XCTAssertEqual(VerificationCommands(build: "  go build ./...  ").build, "go build ./...")
    }

    func testWorkerSectionIsAbsentWhenNeitherCommandIsSet() {
        XCTAssertNil(VerificationCommands().workerSection)
    }

    func testWorkerSectionNamesBothCommandsAndDemandsTheAgentSayWhatItRan() throws {
        let section = try XCTUnwrap(VerificationCommands(build: "make", test: "make check").workerSection)

        XCTAssertTrue(section.contains("This project builds with `make` and tests with `make check`."), section)
        XCTAssertTrue(section.contains("name in your report exactly what you ran"), section)
    }

    func testWorkerSectionCoversTheHalfThatIsNotSet() throws {
        let section = try XCTUnwrap(VerificationCommands(test: "go test ./...").workerSection)

        XCTAssertTrue(section.contains("This project tests with `go test ./...`."), section)
        XCTAssertTrue(section.contains("read its build files, scripts and CI config"), section)
    }
}

final class OpeningPromptVerificationTests: XCTestCase {
    private func task() -> BoardTask {
        BoardTask(
            id: BoardId.new(), projectId: "p", epicId: nil, title: "t", body: nil, acceptance: nil,
            priority: nil, column: .ready, ordering: 1, origin: .human,
            createdAt: .nowMillis, updatedAt: .nowMillis
        )
    }

    func testWorkerPromptCarriesTheProjectsCommandsWhenSet() {
        let prompt = OpeningPrompt.compose(
            task: task(), branch: "agentboard/x", attempt: 1,
            verification: VerificationCommands(build: "pnpm build", test: "pnpm test")
        )

        XCTAssertTrue(prompt.contains("## Verification"), prompt)
        XCTAssertTrue(prompt.contains("builds with `pnpm build` and tests with `pnpm test`"), prompt)
        XCTAssertFalse(prompt.contains("swift build"), prompt)
    }

    func testWorkerPromptIsUnchangedWhenNoCommandsAreSet() {
        let prompt = OpeningPrompt.compose(task: task(), branch: "agentboard/x", attempt: 1)

        XCTAssertFalse(prompt.contains("## Verification"), prompt)
        XCTAssertFalse(prompt.contains("swift build"), prompt)
        XCTAssertFalse(prompt.contains("swift test"), prompt)
    }
}
