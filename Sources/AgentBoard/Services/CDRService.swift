import AgentBoardRuntime
import Foundation

/// What the Reviews screen reads CDR through and starts and stops it with (SPEC §13.7). A test hands in a fake.
protocol CDRService: Sendable {
    var isInstalled: Bool { get }
    /// `command` reads the escalations while the daemon is not running.
    func snapshot(command: CDRCommand?) async -> CDRSnapshot
    /// Reads the plugin registry and the login-shell PATH, so call it off the main actor.
    func resolveCommand(configured: String?) -> Result<CDRCommand, CDRCommandError>
    /// Blocks until CDR's CLI exits, up to its timeout, so call it off the main actor.
    func setDaemon(running: Bool, using command: CDRCommand) throws
}

struct LiveCDRService: CDRService {
    var client = CDRClient()

    var isInstalled: Bool { FileManager.default.fileExists(atPath: client.home.url.path) }

    func snapshot(command: CDRCommand?) async -> CDRSnapshot {
        await client.snapshot(command: command)
    }

    func resolveCommand(configured: String?) -> Result<CDRCommand, CDRCommandError> {
        CDRCommand.resolve(configured: configured)
    }

    func setDaemon(running: Bool, using command: CDRCommand) throws {
        _ = running ? try command.start() : try command.stop()
    }
}
