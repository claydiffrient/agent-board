import AgentBoardCore
import Foundation

/// Runs a project's cleanup command the way `WorktreeManager` runs a teardown hook: `/bin/zsh -c`,
/// as the leader of its own process group, bounded on `CLOCK_UPTIME_RAW` (SPEC §14.3). Blocks, so
/// call it off the main thread.
public enum ProjectCleanupRunner {
    /// Nil when no command is set.
    public static func run(
        _ cleanup: ProjectCleanupCommand?, in checkout: URL,
        environment: @autoclosure () -> [String: String] = ChildEnvironment.sanitized()
    ) -> ProjectCleanupResult? {
        guard let cleanup else { return nil }
        var env = environment()
        env["PWD"] = checkout.path
        func result(_ outcome: ProjectCleanupResult.Outcome, _ output: String = "") -> ProjectCleanupResult {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return ProjectCleanupResult(
                command: cleanup.command, checkoutPath: checkout.path, timeoutSeconds: cleanup.timeoutSeconds,
                outcome: outcome, outputTail: String(trimmed.suffix(ProjectCleanupResult.outputKept))
            )
        }
        do {
            let run = try BoundedCommand.run(
                executable: "/bin/zsh", arguments: ["-c", cleanup.command], cwd: checkout, environment: env,
                timeout: TimeInterval(cleanup.timeoutSeconds)
            )
            switch run.ending {
            case .exited(let status): return result(.exited(status), run.output)
            case .timedOut, .canceled: return result(.timedOut, run.output)
            }
        } catch {
            return result(.couldNotStart("\(error)"))
        }
    }
}
