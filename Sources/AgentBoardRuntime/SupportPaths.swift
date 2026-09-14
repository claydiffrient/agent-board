import Foundation

public enum SupportPaths {
    public static let supportDirEnvKey = "AGENTBOARD_SUPPORT_DIR"

    public static func appSupportDir(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let override = environment[supportDirEnvKey], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return home.appendingPathComponent("Library/Application Support/AgentBoard")
    }

    /// Worktree paths reach `/bin/sh` through repo setup that does not always quote them, so the
    /// default base stays clear of the space in "Application Support". The override still wins, which
    /// is what keeps the headless E2E harness inside its scratch directory.
    public static func worktreeBase(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let override = environment[supportDirEnvKey], !override.isEmpty {
            return URL(fileURLWithPath: override).appendingPathComponent("worktrees")
        }
        return home.appendingPathComponent(".agentboard/worktrees")
    }

    public static func worktreeRoot(
        projectId: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        worktreeBase(environment: environment, home: home).appendingPathComponent(projectId)
    }
}
